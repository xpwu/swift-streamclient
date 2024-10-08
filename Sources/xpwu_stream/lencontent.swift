//
//  File.swift
//  
//
//  Created by xpwu on 2024/9/26.
//

import Foundation
import xpwu_x
import xpwu_concurrency

/*
lencontent protocol:

 1, handshake protocol:

									 client ------------------ server
											|                          |
											|                          |
									 ABCDEF (A^...^F = 0xff) --->  check(A^...^F == 0xff) --- N--> over
										(A is version)
											|                          |
											|                          |Y
											|                          |
 version 1:   set client heartbeat  <----- HeartBeat_s (2 bytes, net order)
 version 2:       set config     <-----  HeartBeat_s | FrameTimeout_s | MaxConcurrent | MaxBytes | connect id
																					HeartBeat_s: 2 bytes, net order
																					FrameTimeout_s: 1 byte
																					MaxConcurrent: 1 byte
																					MaxBytes: 4 bytes, net order
																					connect id: 8 bytes, net order
											|                          |
											|                          |
											|                          |
											data      <-------->       data


	 2, data protocol:
		 1) length | content
			 length: 4 bytes, net order; length=sizeof(content)+4; length=0 => heartbeat
*/

public class LenContent {
	fileprivate var config: Option.Value = Option.Value()
	private var handshake: Handshake = Handshake()
	private var task: URLSessionStreamTask?
	private var urlSession: URLSession?
	private let mutex: Mutex = Mutex()
	private var closedBySelf = ClosedBySelf()
	private let heartbeatStop: Channel<Bool> = Channel(buffer: .Unlimited)
	
	public var logger_: Logger = PrintLogger()
	public var onMessage: (Data)async -> Void = { _ in}
	public var onError: (StmError)async -> Void = { _ in}
	public var logger: Logger {
		get {
			logger_
		}
		set {
			logger_ = newValue
			logger_.Debug("LenContent[\(flag)].new", "flag=\(flag)")
		}
	}
	
	private let flag = UniqFlag()
	private var connectID:String {get{self.handshake.ConnectId}}
	
	public convenience init(_ options: Option...) {
		self.init(options)
	}
	
	public init(_ options: [Option]) {
		for option in options {
			option.runner(&config)
		}
	}
	
	deinit {
		task?.cancel()
		urlSession?.invalidateAndCancel()
	}
}

public extension LenContent {
	struct Option {
		fileprivate struct Value: CustomStringConvertible {
			var description: String {
				get {
					let pre = tls ? "<tls>" : ""
					return "\(pre)\(host):\(port)#connectTimeout=\(connectionTimeout.toString)"
				}
			}
			
			var host: String = "127.0.0.1"
			var port: Int = 8080
			var connectionTimeout: Duration = 30*Duration.Second
			
			var tls: Bool = false
			var tlsF: (URLSession, URLSessionTask
								 , URLAuthenticationChallenge)async->(URLSession.AuthChallengeDisposition
																											, URLCredential?) = {_,_,_ in
				return (.performDefaultHandling, nil)}
		}
		
		fileprivate let runner: (inout Value)->Void
		
		fileprivate init(_ runner: @escaping (inout Value) -> Void) {
			self.runner = runner
		}
		
		public static func Host(_ host: String)-> Option {
			return Option { value in
				value.host = host
			}
		}
		public static func Port(_ port: Int)-> Option {
			return Option { value in
				value.port = port
			}
		}
		public static func ConnectTimeout(_ t: Duration)-> Option {
			return Option { value in
				value.connectionTimeout = t
			}
		}
		public static func TLS()-> Option {
			return Option { value in
				value.tls = true
				value.tlsF = {_,_,_ in return (.performDefaultHandling, nil)}
			}
		}
		
		// https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/1411595-urlsession
		public static func TLS(with tlsf: @escaping (URLSession, URLSessionTask
														, URLAuthenticationChallenge)async->(URLSession.AuthChallengeDisposition
																																 , URLCredential?))-> Option {
			return Option { value in
				value.tls = true
				value.tlsF = tlsf
			}
		}
	}
}

func handshakeReq() -> Data {
	var handshake = Data(repeating: 0, count: 6)
	// version: 2
	handshake[0] = 2
	handshake[1] = Byte(Int.random(in: 0..<256))
	handshake[2] = Byte(Int.random(in: 0..<256))
	handshake[3] = Byte(Int.random(in: 0..<256))
	handshake[4] = Byte(Int.random(in: 0..<256))
	handshake[5] = 0xff
	for i in 0..<5 {
		handshake[5] ^= handshake[i]
	}
	
	return handshake
}

extension LenContent {
	func read() {
		Task {
			logger.Debug("LenContent[\(flag)]<\(connectID)>.read:start", "run async loop...")
			while task?.state == .running {
				logger.Debug("LenContent[\(flag)]<\(connectID)>.read", "waiting for a message")
				do {
					var (data, eof) = try await task!.readData(ofMinLength: 1, maxLength: 4
																	 , timeout:(2*self.handshake.HearBeatTime).timeInterval())
					if data == nil  || eof {
						logger.Debug("LenContent[\(flag)]<\(connectID)>.read:readLength"
												 , "error --- data==nil || eof")
						throw StmError.ElseConnErr("read length error, maybe connection closed by peer")
					}
					
					var len: UInt32 = data!.toBytes().net2UInt32()
					// heartbeat
					if len == 0 {
						logger.Debug("LenContent[\(flag)]<\(connectID)>.read:Heartbeat"
												 , "receive heartbeat from server")
						continue
					}
					
					len -= 4
					// 出现这种情况，很可能是协议出现问题了，而不能单纯的认为是本次请求的问题
					if len > self.handshake.MaxBytes + UInt32(FakeHttp.Response.MaxNoLoadLen) {
						logger.Debug("LenContent[\(flag)]<\(connectID)>.read:MaxBytes"
												, "error: data(len: \(len) > maxbytes: \(handshake.MaxBytes) is Too Large")
						
						throw StmError.ElseConnErr("received Too Large data(len=\(len)), must be less than \(self.handshake.MaxBytes)")
					}
					
					var res: Data = Data()
					while res.count < len {
						(data, eof) = try await task!.readData(ofMinLength: 1, maxLength: Int(len)
																		 , timeout:self.handshake.FrameTimeout.timeInterval())
						if data == nil  || eof {
							logger.Debug("LenContent[\(flag)]<\(connectID)>.read:readContent"
													 , "error --- data==nil || eof")
							throw StmError.ElseConnErr("read content error, maybe connection closed by peer")
						}
						res.append(contentsOf: data!)
					}
					
					logger.Debug("LenContent[\(flag)]<\(connectID)>.read", "read one message")
					await onMessage(res)
				} catch StmError.ElseConnErr(let msg) {
					if !(await closedBySelf.isTrue) {
						await onError(StmError.ElseConnErr(msg))
					}
					break
				} catch {
					logger.Debug("LenContent[\(flag)]<\(connectID)>.read:error", "\(error)")
					if !(await closedBySelf.isTrue) {
						await onError(StmError.ElseConnErr("\(error)"))
					}
					break
				}
			}
			logger.Debug("LenContent[\(flag)]<\(connectID)>.read:end", "run loop is end")
		}
	}
}

// 没有在 delegate 中找到 stream 建立成功后的确定性回调，采用在 didCreateTask 后直接写 handshake
fileprivate class SessionDelegate: NSObject, URLSessionStreamDelegate {
	
	func urlSession(_ session: URLSession, task: URLSessionTask
									, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition
																																								, URLCredential?) {
		
		return await tls(session, task, challenge)
	}
	
	let tls: (URLSession, URLSessionTask
												, URLAuthenticationChallenge)async->(URLSession.AuthChallengeDisposition
																															 , URLCredential?)
	
	init(tls: @escaping (URLSession, URLSessionTask
												 , URLAuthenticationChallenge)async->(URLSession.AuthChallengeDisposition
																															, URLCredential?)) {
		self.tls = tls
	}
}

extension LenContent: `Protocol` {
	
	public func Connect() async -> (Handshake, StmError?) {
		logger.Debug("LenContent[\(flag)].Connect:start", "\(self.config)")
		
		let c = URLSessionConfiguration.default
		c.timeoutIntervalForRequest = TimeInterval(config.connectionTimeout.second())
		
		self.urlSession = URLSession(configuration: c, delegate: SessionDelegate(tls: config.tlsF), delegateQueue: nil)
		let task = self.urlSession!.streamTask(withHostName: config.host, port: config.port)
		
		task.resume()
		
		if config.tls {
			task.startSecureConnection()
		}
		
		do {
			logger.Debug("LenContent[\(flag)].Connect:handshake", "write handshake ...")
			try await task.write(handshakeReq(), timeout: TimeInterval(config.connectionTimeout.second()))
			let (h, eof) = try await task.readData(ofMinLength: Handshake.StreamLen, maxLength: Handshake.StreamLen
													, timeout: TimeInterval(config.connectionTimeout.second()))
			if eof {
				logger.Debug("LenContent[\(flag)].Connect:readHandshake", "connected eof")
				throw StmError.ElseConnErr("connected eof")
			}
			
			guard let h else {
				logger.Debug("LenContent[\(flag)].Connect:readHandshake", "no handshake response")
				throw StmError.ElseConnErr("no handshake response")
			}
			
			self.handshake = Handshake.Parse(h)
			logger.Debug("LenContent[\(flag)]<\(connectID)>.readHandshake:handshake", "\(self.handshake)")
			
			self.setOutputHeartbeat()
			self.read()
			
		}catch  {
			logger.Debug("LenContent[\(flag)].Connect:handshake", "error --- \(error)")
			task.cancel()
			urlSession!.invalidateAndCancel()
			return (Handshake(), StmError.ElseConnErr("\(error)"))
		}

		self.task = task
		
		logger.Debug("LenContent[\(flag)]<\(connectID)>.Connect:end", "connectID = \(connectID)")
		return (self.handshake, nil)
	}
	
	public func Close() async throws/*(CancellationError)*/ {
		await closedBySelf.yes()
		task?.cancel()
		task = nil
		urlSession?.invalidateAndCancel()
		urlSession = nil
		try await stopOutputHeartbeat()
	}
	
	public func Send(content: Data) async throws/*(CancellationError)*/ -> StmError? {
		
		var len:Data = Data(repeating: 0, count: 4)
		UInt32(content.count + 4).toNet(&len)
		
		try await stopOutputHeartbeat()
		
		let ret = try await mutex.withLock {()->StmError? in
			do {
				logger.Debug("LenContent[\(flag)]<\(connectID)>.Send:start", "frameBytes = \(content.count + 4)")
				
				try await task?.write(len, timeout: TimeInterval(self.handshake.FrameTimeout.second()))
				try await task?.write(content, timeout: TimeInterval(self.handshake.FrameTimeout.second()))
				
				logger.Debug("LenContent[\(flag)]<\(connectID)>.Send:end", "end")
				return nil
			} catch {
				logger.Debug("LenContent[\(flag)]<\(connectID)>.Send:error", "\(error)")
				await onError(.ElseConnErr("\(error)"))
				return .ElseConnErr("\(error)")
			}
		}
		
		setOutputHeartbeat()
		
		return ret
	}
}

// output heartbeat
extension LenContent {
	func setOutputHeartbeat() {
		Task {
			logger.Debug("LenContent[\(flag)]<\(connectID)>.outputHeartbeat:set", "set")
			let timeout = try await withTimeoutOrNil(self.handshake.HearBeatTime) {
				try await self.heartbeatStop.Receive() ?? false
			}
			
			// not timeout: stopped or else error
			if timeout != nil {
				logger.Debug("LenContent[\(flag)]<\(connectID)>.outputHeartbeat:stopped", "stopped")
				return
			}
			
			logger.Debug("LenContent[\(flag)]<\(connectID)>.outputHeartbeat:send", "send heartbeat to server")
			let ok = try await mutex.withLock {
				do {
					try await self.task?.write(Data(repeating: 0, count: 4)
																		 , timeout: self.handshake.FrameTimeout.timeInterval())
					return true
				} catch {
					await self.onError(.ElseErr("\(error)"))
					return false
				}
			}
			
			if ok  {
				setOutputHeartbeat()
			}
		}
	}
	
	/**
	 * stop 后必须调用 set
	 * heartbeat 后必须再次调用
	 * 可以多发 heartbeat，但不能不发 heartbeat
	 */
	func stopOutputHeartbeat()async throws/*(CancellationError)*/ {
		logger.Debug("LenContent[\(flag)]<\(connectID)>.outputHeartbeat", "will stop")
		_ = try await self.heartbeatStop.Send(true)
	}
}
