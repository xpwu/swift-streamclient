// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import xpwu_x
import xpwu_concurrency

public class Client {
	let logger: Logger
	var protocolCreator: ()->`Protocol`
	
	public var onPush: ([Byte])async->Void = {_ in }
	public var onPeerClosed: (StmError)async->Void = {_ in }
	
	let flag = UniqFlag()
	private let mutex: Mutex = Mutex()
	private var net_: Net?
	
	init(_ logger: Logger = PrintLogger(), _ protocolCreator: @escaping () -> Protocol) {
		self.protocolCreator = protocolCreator
		self.logger = logger
	}
}

private extension Client {
	func newNet()->Net {
		return Net(self.logger, protocolCreator: self.protocolCreator
							 , onPeerClosed: {
			[unowned self] error in
			await self.onPeerClosed(error)
		}, onPush: {[unowned self] error in
			await self.onPush(error)
		})
	}
	
	func net()async ->Net {
		return await mutex.WithLock {
			if self.net_ == nil || self.net_!.isInValid {
				await self.net_?.close()
				self.net_ = newNet()
			}
			return self.net_!
		}
	}
}

public extension Client {

	func Send(_ data: [Byte], withheaders headers:[String:String]
						, timeout: Duration = 30*Duration.Second)async -> ([Byte], StmError?) {
		
		let net = await net()
		let err = await net.connect()
		if let err {
			return ([], err)
		}
		
		let ret = await net.send(data: data, headers: headers, timeout: timeout)
		if ret.1 == nil {
			return ret
		}
		if !ret.1!.isConnErr {
			return ret
		}
		
		// sending --- conn error:  retry
		let net2 = await self.net()
		let err2 = await net2.connect()
		if let err2 {
			return ([], err)
		}
		
		return await net.send(data: data, headers: headers, timeout: timeout)
	}
	
	private static let reqidKey: String = "X-Req-Id"
	
	func SendWithReqId(_ data: [Byte], withheaders headers:[String:String]
										 , timeout: Duration = 30*Duration.Second)async -> ([Byte], StmError?) {
		
		var newHeaders = headers
		newHeaders[Client.reqidKey] = UUID().uuidString
		
		return await self.Send(data, withheaders: newHeaders, timeout: timeout)
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
		await mutex.WithLock {
			await self.net_?.close()
		}
	}
	
	func UpdateProtocol(creator: @escaping()->`Protocol`) {
		self.protocolCreator = creator
	}
	
	func Recover()async->StmError? {
		return await net().connect()
	}
}

// LenContent
public extension Client {
	static func WithLenContent(_ options: LenContent.Option..., logger: Logger = PrintLogger())->Client {
		return Client(logger) {
			return LenContent(options)
		}
	}
	
	func UpdateOptions(_ options: LenContent.Option...) {
		self.UpdateProtocol {
			return LenContent(options)
		}
	}
}
