//
//  File.swift
//  
//
//  Created by xpwu on 2024/9/26.
//

import Foundation
import xpwu_concurrency
import xpwu_x


fileprivate class SyncAllRequest {
	fileprivate typealias RequestChannel = Channel<(FakeHttp.Response, StmError?)>
	
	let mutex: Mutex = Mutex()
	private var allRequests: [UInt32:RequestChannel] = [:]
	var semaphore: xpwu_concurrency.Semaphore = Semaphore(permits: 3)
	
	public var permits: Int {
		get {semaphore.Permits}
		set {semaphore = Semaphore(permits: newValue)}
	}
	
	init(permits: Int = 3) {
		semaphore = Semaphore(permits: permits)
	}
}

// channel 必须在 SyncAllRequest 的控制下，所以 Add 获取的只能 receive
// 要 send 就必须通过 remove 获取
extension SyncAllRequest {
	
	func Add(reqId: UInt32) async -> some ReceiveChannel<(FakeHttp.Response, StmError?)> {
		await semaphore.Acquire()
		return await mutex.WithLock {
			let ch = RequestChannel(buffer: 1)
			allRequests[reqId] = ch
			return ch
		}
	}
	
	// 可以用同一个 reqid 重复调用
	func Remove(reqId: UInt32) async -> (some SendChannel<(FakeHttp.Response, StmError?)>)? {
		return await mutex.WithLock {
			let ret = allRequests.removeValue(forKey: reqId)
			// todo: check semaphore
			if ret != nil {
				await semaphore.Release()
			}
			
			return ret
		}
	}
	
	func ClearAllWith(ret: (FakeHttp.Response, StmError?)) async {
		await mutex.WithLock {
			for (_, ch) in allRequests {
				await ch.Send(ret)
			}
			allRequests.removeAll()
			await semaphore.ReleaseAll()
		}
	}
}

/**
 *
 *    NotConnect  ---> (Connecting)  ---> Connected ---> Invalidated
 *                          |                                ^
 *                          |                                |
 *                          |________________________________|
 *
 */

fileprivate enum State {
	case NotConnect, Connected, Invalidated(StmError)
}

extension State: CustomStringConvertible {
	var description: String {
		switch self {
		case .NotConnect:
			return "NotConnect"
		case .Connected:
			return "Connected"
		case .Invalidated:
			return "Invalidated"
		}
	}
}

extension State: Equatable {
	static func == (lhs: State, rhs: State) -> Bool {
		switch lhs {
		case .NotConnect:
			switch rhs {
			case .NotConnect:
				return true
			default :
				return false
			}
		case .Connected:
			switch rhs {
			case .Connected:
				return true
			default:
				return false
			}
		case .Invalidated(let stmError):
			switch rhs {
			case .Invalidated(let stmError):
				return true
			default:
				return false
			}
		}
	}
	
	var isInvalidated: Bool {
		get { self == .Invalidated(StmError.ElseErr(""))}
	}
}

actor ReqId {
	private static let reqIdStart: UInt32 = 10
	
	var value: UInt32 = reqIdStart
	
	func get()-> UInt32 {
		value += 1
		if value < ReqId.reqIdStart || value > UInt32.max {
			value = ReqId.reqIdStart
		}
		
		return value
	}
}

class Net {
	private let logger: Logger
	private let onPeerClosed: (StmError) async -> Void
	private let onPush: ([Byte]) async -> Void
	
	var isInValid: Bool {
		get { state.isInvalidated }
	}

	private var handshake: Handshake = Handshake()

	private let connLocker: Mutex = Mutex()
	private var state: State = State.NotConnect
	private var proto: `Protocol`

	private var reqId: ReqId = ReqId()
	private var allRequests: SyncAllRequest = SyncAllRequest()

	private let flag = UniqFlag()
	
	var connectID: String {
		get {handshake.ConnectId}
	}

	init(_ l: Logger, protocolCreator:()->`Protocol`
			 , onPeerClosed: @escaping(StmError)async->Void, onPush: @escaping([Byte])async->Void) {
		self.logger = l
		self.onPush = onPush
		self.onPeerClosed = onPeerClosed
		
		self.proto = protocolCreator()
		self.proto.logger = l
		self.proto.onError = {[unowned self](err)async->Void in await self.onError(err)}
		self.proto.onMessage = {[unowned self](msg)async->Void in await self.onMessage(msg)}
		
		logger.Debug("Net[$flag].new", "flag=$flag, protocol.hashcode=$ph")
	}
}

private extension Net {
	func closeAndOldState(err: StmError) async -> State {
		let old = await connLocker.WithLock {
			let old = self.state
			
			if self.state.isInvalidated {
				return old
			}
			self.state = .Invalidated(err)
			
			return old
		}
		
		await allRequests.ClearAllWith(ret: (FakeHttp.Response(), err.toConnError))
		
		return old
	}
}

extension Net {
	// 可重复调用
	func connect()async -> StmError? {
		return await connLocker.WithLock {
			if state == .Connected {
				return nil
			}
			if case State.Invalidated(let err) = state {
				return err
			}
			
			// state.NotConnect
			let(handshake, err) = await self.proto.Connect()
			if let e = err {
				self.state = .Invalidated(e)
				return e
			}
			
			// OK
			self.state = .Connected
			self.handshake = handshake
			self.allRequests.permits = self.handshake.MaxConcurrent
			
			return nil
		}
	}
	
	// 如果没有连接成功，直接返回失败
	func send(data: [Byte], headers:[String:String]
						, timeout:Duration = 30*Duration.Second) async -> ([Byte], StmError?) {
		// 预判断
		let ret = await connLocker.WithLock { ()->StmError? in
			if case State.Invalidated(let err) = state {
				return err.toConnError
			}
			if state != .Connected {
				return .ElseConnErr("not connected")
			}
			return nil
		}
		if let ret {
			return ([], ret)
		}
		
		let reqId = await self.reqId.get()
		let (request, err) = FakeHttp.Request.New(reqId: reqId, body: data, headers: headers)
		if let err {
			return ([], err)
		}
		if request.encodedData.count > self.handshake.MaxBytes {
			return ([], .ElseErr("request.size(\(request.encodedData.count)) > MaxBytes(\(handshake.MaxBytes))"))
		}
		
		// 在客户端超时也认为是一个请求结束，但是真正的请求并没有结束，所以在服务器看来，仍然占用服务器的一个并发数
		// 因为网络异步的原因，客户端并发数不可能与服务器完全一样，所以这里主要是协助服务器做预控流，按照客户端的逻辑处理即可
		
		let ch = await allRequests.Add(reqId: reqId)
		let ret2 = await WithTimeout(timeout) {
			Task {
				let err = await self.proto.Send(content:request.encodedData)
				if let err {
					await self.allRequests.Remove(reqId: reqId)?.Send((FakeHttp.Response(), err))
				}
			}
			return await ch.Receive()
		}
		// timeout: ret2 == nil
		guard let ret2 else {
			return ([], .ElseTimeoutErr("request timeout(\(timeout.second())s)"))
		}
		
		if let err = ret2.1 {
			return ([], err)
		}
		
		if ret2.0.status != .OK {
			return ([],.ElseErr(String(decoding: ret2.0.data, as: UTF8.self)))
		}
		
		_ = await allRequests.Remove(reqId: reqId)
		
		return (ret2.0.data, nil)
	}
	
	func close()async {
		let oldState = await closeAndOldState(err: .ElseErr("closed by self"))
		if oldState == .Connected {
			await self.proto.Close()
		}
	}
}

// delegate
extension Net {
	func onMessage(_ msg: [Byte]) async {
		let (response, err) = msg.Parse()
		if let err {
			await onError(err)
			return
		}
		
		if response.isPush {
			let (pushAck, err) = response.newPushAck()
			if let err {
				await onError(err)
				return
			}
			
			async let _ = self.onPush(response.data)
			// ignore error
			async let _ = self.proto.Send(content: pushAck)
			return
		}
		
		let ch = await allRequests.Remove(reqId: response.reqId)
		guard let ch else {
			return
		}
		
		async let _ = ch.Send((response, nil))
	}
	
	func onError(_ err: StmError) async {
		let oldState = await closeAndOldState(err: err)
		if oldState == .Connected {
			async let _ = self.onPeerClosed(err)
			await self.proto.Close()
		}
	}
}
