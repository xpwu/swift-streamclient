// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import xpwu_x
import xpwu_concurrency

public final class Client: @unchecked Sendable {
	public var onPush: @Sendable(Data)async->Void = {_ in }
	public var onPeerClosed: @Sendable(StmError)async->Void = {_ in }
	
	let logger: Logger
	let flag = UniqFlag()
	
	private let mutex: Mutex = Mutex()
	private var net_: Net?
	var protocolCreator: @Sendable()->`Protocol`
	
	init(_ logger: Logger = PrintLogger(), _ protocolCreator: @Sendable @escaping () -> Protocol) {
		self.protocolCreator = protocolCreator
		self.logger = logger
		logger.Info("Client[\(flag)].new", "flag=\(flag)")
	}
}

private extension Client {
	func newNet()->Net {
		return Net(self.logger, protocolCreator: self.protocolCreator
							 , onPeerClosed: {
			[unowned self] error in
			logger.Warning("Client[\(flag)].onPeerClosed", "reason: \(error)")
			await self.onPeerClosed(error)
		}, onPush: {[unowned self] data in
			logger.Info("Client[\(flag)].onPush", "size: \(data.count)")
			await self.onPush(data)
		})
	}
	
	func net()async throws/*(CancellationError)*/ ->Net {
		return try await mutex.withLock {
			if self.net_ == nil || self.net_!.isInValid {
				try await self.net_?.close()
				self.net_ = newNet()
			}
			return self.net_!
		}
	}
}

public extension Client {

	func Send(_ data: Data, withheaders headers:[String:String]
						, timeout: Duration = 30*Duration.Second)async -> (Data, StmError?) {
		let sflag = headers[Client.reqidKey] ?? UniqFlag()
		logger.Info("Client[\(flag)].Send[\(sflag)]:start", "\(headers), request size = \(data.count)")
		
		do {
			
			let net = try await net()
			
			let err = try await net.connect()
			if let err {
				logger.Error("Client[\(flag)].Send[\(sflag)]:error", "connect error: \(err)")
				return (Data(), err)
			}
			
			let ret = try await net.send(data: data, headers: headers, timeout: timeout)
			if ret.1 == nil {
				logger.Info("Client[\(flag)].Send[\(sflag)](connID=\(net.connectID):end", "response size = \(ret.0.count)")
				return ret
			}
			if !ret.1!.isConnErr {
				logger.Error("Client[\(flag)].Send[\(sflag)](connID=\(net.connectID):error", "request error = \(ret.1!)")
				return ret
			}
			
			// sending --- conn error:  retry
			logger.Debug("Client[\(flag)].Send[\(sflag)]:retry", "retry-1")
			
			let net2 = try await self.net()
			
			let err2 = try await net2.connect()
			if let err2 {
				logger.Error("Client[\(flag)].Send[\(sflag)]:error", "connect error: \(err2)")
				return (Data(), err)
			}
			
			let ret2 = try await net.send(data: data, headers: headers, timeout: timeout)
			if ret2.1 == nil {
				logger.Info("Client[\(flag)].Send[\(sflag)](connID=\(net.connectID)):end", "response size = \(ret2.0.count)")
			} else {
				logger.Error("Client[\(flag)].Send[\(sflag)](connID=\(net.connectID)):error", "request error = \(ret2.1!)")
			}
			
			return ret2
			
		}catch {
			return (Data(), .ElseErr("task canceled", cause: CancellationError()))
		}
	}
	
}

public extension Client {
	/**
	 * Close 后，Client 仍可继续使用，下次发送请求时，会自动重连
	 * Close() 调用不会触发 onPeerClosed()
	 * Close() 与 其他接口没有明确的时序关系，Close() 调用后，也可能会出现 Send() 的调用返回 或者 onPeerClosed()
	 * 		但此时的 onPeerClosed() 并不是因为 Close() 而触发的。
	 */
	
	func Close() async {
		do {
			try await mutex.withLock {
				logger.Info("Client[\(flag)].close", "closed by self")
				try await self.net_?.close()
			}
		}catch {
			logger.Warning("Client[\(flag)].close:catch", "\(error)")
		}
	}
	
	func UpdateProtocol(creator: @Sendable @escaping()->`Protocol`) {
		Task {
			try await mutex.withLock {
				self.protocolCreator = creator
			}
		}
	}
	
	func Recover()async ->StmError? {
		do {
			return try await net().connect()
		}catch {
			logger.Warning("Client[\(flag)].Recover:catch", "\(error)")
			return .ElseErr("recover canceled by task", cause: CancellationError())
		}
	}
}


