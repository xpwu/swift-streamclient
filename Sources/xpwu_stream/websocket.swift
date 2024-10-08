//
//  File.swift
//  
//
//  Created by xpwu on 2024/9/30.
//

import Foundation
import xpwu_x
import xpwu_concurrency

public class WebSocket {
	fileprivate var config: Option.Value = Option.Value()
	private var handshake: Handshake = Handshake()
	private var task: URLSessionWebSocketTask?
	private var urlSession: URLSession?
	private var closedBySelf = ClosedBySelf()
	
	public var logger_: Logger = PrintLogger()
	public var onMessage: (Data)async -> Void = { _ in}
	public var onError: (StmError)async -> Void = { _ in}
	public var logger: Logger {
		get {
			logger_
		}
		set {
			logger_ = newValue
			logger_.Debug("WebSocket[\(flag)].new", "flag=\(flag)")
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
	}
}

public extension WebSocket {
	struct Option {
		fileprivate struct Value: CustomStringConvertible {
			var description: String {
				get {
					return "\(url)#connectTimeout=\(connectionTimeout.toString)"
				}
			}
			
			var url: String = "ws://127.0.0.1:8080"
			var connectionTimeout: Duration = 30*Duration.Second
		}
		
		fileprivate let runner: (inout Value)->Void
		
		fileprivate init(_ runner: @escaping (inout Value) -> Void) {
			self.runner = runner
		}
		
		public static func Url(_ url: String)-> Option {
			return Option { value in
				value.url = url
			}
		}
		public static func ConnectTimeout(_ t: Duration)-> Option {
			return Option { value in
				value.connectionTimeout = t
			}
		}
	}
}

extension WebSocket {
	func read() {
		Task {
			logger.Debug("WebSocket[\(flag)]<\(connectID)>.read:start", "run async loop...")
			while task?.state == .running {
				logger.Debug("WebSocket[\(flag)]<\(connectID)>.read", "waiting for a message")
				do {
					let msg = try await self.task?.receive()
			
					switch msg {
					case .data(let message):
						logger.Debug("WebSocket[\(flag)]<\(connectID)>.read", "read one message")
						await onMessage(message)
						
					default:
						throw StmError.ElseConnErr("message type error")
					}
				} catch StmError.ElseConnErr(let msg) {
					if !(await closedBySelf.isTrue) {
						await onError(StmError.ElseConnErr(msg))
					}
					break
				} catch {
					logger.Debug("WebSocket[\(flag)]<\(connectID)>.read:error", "\(error)")
					if !(await closedBySelf.isTrue) {
						await onError(StmError.ElseConnErr("\(error)"))
					}
					break
				}
			}
			logger.Debug("WebSocket[\(flag)]<\(connectID)>.read:end", "run loop is end")
		}
	}
}

fileprivate class SessionDelegate: NSObject, URLSessionWebSocketDelegate {
	func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol: String?) {
		onOpen(nil)
	}
	
	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
		if let error {
			onOpen(.ElseConnErr("\(error)"))
		}
	}
	
	func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask
									, didCloseWith: URLSessionWebSocketTask.CloseCode, reason: Data?) {
		var reasonS = "on reason"
		if let reason {
			reasonS =  "reason: " + (String(data: reason, encoding: .utf8) ?? "unknown")
		}
		onClose(.ElseConnErr("code: \(didCloseWith), \(reasonS)"))
	}
	
	var onOpen: (StmError?)->Void = {_ in}
	let onClose: (StmError)->Void
	
	init(onClose: @escaping(StmError)->Void) {
		self.onClose = onClose
	}
}

extension WebSocket: `Protocol` {
	
	public func Connect() async -> (Handshake, StmError?) {
		logger.Debug("WebSocket[\(flag)].Connect:start", "\(self.config)")
		
		guard let url = URL(string: self.config.url) else {
			return (Handshake(), .ElseConnErr("\(self.config.url) can not convert to URL"))
		}
		
		let delegate = SessionDelegate { [weak self]err in
			Task {[weak self] in
				let byself = await self?.closedBySelf.isTrue ?? true
				if !byself {
					await self?.onError(err)
				}
			}
		}
		
		let c = URLSessionConfiguration.default
		c.timeoutIntervalForRequest = TimeInterval(config.connectionTimeout.second())
		self.urlSession = URLSession(configuration: c, delegate: delegate, delegateQueue: nil)
		self.task = self.urlSession!.webSocketTask(with: url)
		
		do {
			let ret = try await withSuspend {[weak task = self.task](suspend:Suspend<StmError?>) in
				delegate.onOpen = {
					suspend.resume(returning: $0)
				}
				
				task?.resume()
			}
			
			if let ret {
				throw ret
			}
			
			let msg = try await self.task?.receive()
	
			switch msg {
			case .data(let handshake):
				if handshake.count != Handshake.StreamLen {
					throw StmError.ElseConnErr("handshake size error")
				}
				self.handshake = Handshake.Parse(handshake)
				task!.maximumMessageSize = Int(self.handshake.MaxBytes)
				
			default:
				throw StmError.ElseConnErr("handshake type error")
			}
			
			self.read()
			
		}catch {
			logger.Debug("WebSocket[\(flag)].Connect:handshake", "error --- \(error)")
			self.task?.cancel()
			self.urlSession?.invalidateAndCancel()
			if let err = error as? StmError {
				return (Handshake(), err)
			}
			
			return (Handshake(), StmError.ElseConnErr("\(error)"))
		}
		
		logger.Debug("WebSocket[\(flag)]<\(connectID)>.Connect:end", "connectID = \(connectID)")
		return (self.handshake, nil)
	}
	
	public func Close() async throws/*(CancellationError)*/ {
		await closedBySelf.yes()
		task?.cancel()
		urlSession?.invalidateAndCancel()
	}
	
	public func Send(content: Data) async throws/*(CancellationError)*/ -> StmError? {
		if content.count > self.handshake.MaxBytes {
			return StmError.ElseErr("request.size(\(content.count)) > MaxBytes(\(self.handshake.MaxBytes))")
		}
		
		do {
			logger.Debug("WebSocket[\(flag)]<\(connectID)>.Send:start", "frameBytes = \(content.count)")
			
			try await task?.send(.data(content))
			
			logger.Debug("WebSocket[\(flag)]<\(connectID)>.Send:end", "end")
			return nil
		} catch {
			logger.Debug("WebSocket[\(flag)]<\(connectID)>.Send:error", "\(error)")
			await onError(.ElseConnErr("\(error)"))
			return .ElseConnErr("\(error)")
		}
	}
}
