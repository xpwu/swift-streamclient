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

private actor ClosedBySelf {
	var bySelf: Bool = false
	
	var isTrue: Bool {
		get {bySelf}
	}
	
	func yes() {
		bySelf = true
	}
}

public class LenContent {
	fileprivate var config: Option.Value = Option.Value()
	private var handshake: Handshake = Handshake()
	private var task: URLSessionStreamTask?
	private let mutex: Mutex = Mutex()
	private var closedBySelf = ClosedBySelf()
	private let heartbeatStop: Channel<Bool> = Channel(buffer: .Unlimited)
	
	public var logger: Logger = PrintLogger()
	public var onMessage: ([Byte])async -> Void = { _ in}
	public var onError: (StmError)async -> Void = { _ in}
	
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
	}
}

public extension LenContent {
	struct Option {
		fileprivate struct Value {
			var host: String = "127.0.0.1"
			var port: Int = 8080
			var connectionTimeout: Duration = 30*Duration.Second
		}
		fileprivate let runner: (inout Value)->Void
		
		fileprivate init(_ runner: @escaping (inout Value) -> Void) {
			self.runner = runner
		}
		
		public static func Host(host: String)-> Option {
			return Option { value in
				value.host = host
			}
		}
		public static func Port(port: Int)-> Option {
			return Option { value in
				value.port = port
			}
		}
		public static func ConnectTimeout(t: Duration)-> Option {
			return Option { value in
				value.connectionTimeout = t
			}
		}
	}
}

fileprivate class SessionDelegate: NSObject, URLSessionStreamDelegate {
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		if let error {
			self.runner(task as! URLSessionStreamTask, .ElseConnErr("\(error)"))
		} else {
			self.runner(task as! URLSessionStreamTask, nil)
		}
	}
	
	fileprivate let runner:(URLSessionStreamTask, StmError?)->Void
	init(_ r: @escaping (URLSessionStreamTask, StmError?)->Void) {
		self.runner = r
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
			while task?.state == .running {
				do {
					var (data, eof) = try await task!.readData(ofMinLength: 1, maxLength: 4
																	 , timeout:(2*self.handshake.HearBeatTime).timeInterval())
					if data == nil  || eof {
						throw StmError.ElseConnErr("read length error, maybe connection closed by peer")
					}
					
					let len: UInt32 = data!.toBytes().net2UInt32()
					// heartbeat
					if len == 0 {
						continue
					}
					
					// 出现这种情况，很可能是协议出现问题了，而不能单纯的认为是本次请求的问题
					if len > self.handshake.MaxBytes {
						throw StmError.ElseConnErr("received Too Large data(len=\(len)), must be less than \(self.handshake.MaxBytes)")
					}
					
					var res: [Byte] = []
					while res.count < len {
						(data, eof) = try await task!.readData(ofMinLength: 1, maxLength: Int(len)
																		 , timeout:self.handshake.FrameTimeout.timeInterval())
						if data == nil  || eof {
							throw StmError.ElseConnErr("read content error, maybe connection closed by peer")
						}
						res.append(contentsOf: data!)
					}
					
					await onMessage(res)
				} catch StmError.ElseConnErr(let msg) {
					if !(await closedBySelf.isTrue) {
						await onError(StmError.ElseConnErr(msg))
					}
					break
				} catch {
					if !(await closedBySelf.isTrue) {
						await onError(StmError.ElseConnErr("\(error)"))
					}
					break
				}
			}
		}
	}
}

extension LenContent: `Protocol` {
	public func Connect() async -> (Handshake, StmError?) {
		let (task, err) = await withCheckedContinuation {
			(continuation: CheckedContinuation<(URLSessionStreamTask, StmError?), Never>) in
			
			var c = URLSessionConfiguration.default
			c.timeoutIntervalForRequest = TimeInterval(config.connectionTimeout.second())
			
			let task = URLSession(configuration: c, delegate: SessionDelegate({
				(task, err) -> Void in
				continuation.resume(returning: (task, err))
			}), delegateQueue: nil).streamTask(withHostName: config.host, port: config.port)
			
			task.resume()
		}
		
		if let err {
			return (Handshake(), err)
		}
		
		do {
			try await task.write(handshakeReq(), timeout: TimeInterval(config.connectionTimeout.second()))
			let (h, eof) = try await task.readData(ofMinLength: Handshake.StreamLen, maxLength: Handshake.StreamLen
													, timeout: TimeInterval(config.connectionTimeout.second()))
			if eof {
				throw StmError.ElseConnErr("connected eof")
			}
			
			guard let h else {
				throw StmError.ElseConnErr("no handshake response")
			}
			
			self.handshake = Handshake.Parse(h.toBytes())
			self.setOutputHeartbeat()
			self.read()
			
		}catch  {
			task.cancel()
			return (Handshake(), StmError.ElseConnErr("\(error)"))
		}

		self.task = task
		return (self.handshake, nil)
	}
	
	public func Close() async {
		task?.cancel()
	}
	
	public func Send(content: [Byte]) async -> StmError? {
		// sizeof(length) = 4
		if content.count + 4 > self.handshake.MaxBytes {
			return StmError.ElseErr("request.size(\(content.count)) > MaxBytes(\(self.handshake.MaxBytes-4))")
		}
		
		var len:[Byte] = [0, 0, 0, 0]
		UInt32(content.count + 4).toNet(&len)
		
		await stopOutputHeartbeat()
		
		let ret = await mutex.WithLock {()->StmError? in
			do {
				try await task?.write(len.toData(), timeout: TimeInterval(self.handshake.FrameTimeout.second()))
				try await task?.write(content.toData(), timeout: TimeInterval(self.handshake.FrameTimeout.second()))
				
				return nil
			} catch {
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
			let timeout = await WithTimeout(self.handshake.HearBeatTime) {
				await self.heartbeatStop.Receive()
			}
			
			// not timeout: stopped
			if let timeout {
				return
			}
			
			let ok = await mutex.WithLock {
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
	
	func stopOutputHeartbeat()async {
		await self.heartbeatStop.Send(true)
	}
}
