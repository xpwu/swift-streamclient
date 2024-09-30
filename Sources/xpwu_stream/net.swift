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

			let ava = await semaphore.AvailablePermits
			if ret != nil && ava < semaphore.Permits{
				await semaphore.Release()
			}
			
			return ret
		}
	}
	
	func ClearAllWith(ret: (FakeHttp.Response, StmError?)) async {
		await mutex.WithLock {
			for (_, ch) in allRequests {
				await ch.Send(ret)
				await ch.Close()
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
		case .Invalidated(_):
			switch rhs {
			case .Invalidated(_):
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
	private let onPush: (Data) async -> Void
	
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
			 , onPeerClosed: @escaping(StmError)async->Void, onPush: @escaping(Data)async->Void) {
		self.logger = l
		self.onPush = onPush
		self.onPeerClosed = onPeerClosed
		
		logger.Debug("Net[\(flag)].new", "flag=\(flag)")
		
		self.proto = protocolCreator()
		self.proto.logger = l
		self.proto.onError = {[weak self](err)async->Void in await self?.onError(err)}
		self.proto.onMessage = {[weak self](msg)async->Void in await self?.onMessage(msg)}
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
			logger.Debug("Net[\(flag)]<\(connectID)>.Invalidated", "\(err)")
			
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
				logger.Debug("Net[\(flag)].connect:Connected", "connID=\(connectID)")
				return nil
			}
			if case State.Invalidated(let err) = state {
				logger.Debug("Net[\(flag)].connect<\(connectID)>:Invalidated", "\(err)")
				return err
			}
			
			// state.NotConnect
			logger.Debug("Net[\(flag)].connect:NotConnect", "will connect")
			let(handshake, err) = await self.proto.Connect()
			if let e = err {
				self.state = .Invalidated(e)
				logger.Debug("Net[\(flag)].connect:error", "\(e)")
				return e
			}
			
			// OK
			self.state = .Connected
			self.handshake = handshake
			self.allRequests.permits = self.handshake.MaxConcurrent
			logger.Debug("Net[\(flag)]<\(connectID)>.connect:handshake", "\(handshake)")
			
			return nil
		}
	}
	
	// 如果没有连接成功，直接返回失败
	func send(data: Data, headers:[String:String]
						, timeout:Duration = 30*Duration.Second) async -> (Data, StmError?) {
		// 预判断
		let ret = await connLocker.WithLock { ()->StmError? in
			logger.Debug("Net[\(flag)]<\(connectID)>.send:state", "\(state) --- \(headers)")
			if case State.Invalidated(let err) = state {
				return err.toConnError
			}
			if state != .Connected {
				return .ElseConnErr("not connected")
			}
			return nil
		}
		if let ret {
			return (Data(), ret)
		}
		
		let reqId = await self.reqId.get()
		let (request, err) = FakeHttp.Request.New(reqId: reqId, body: data, headers: headers)
		if let err {
			logger.Debug("Net[\(flag)]<\(connectID)>.send:FakeHttpRequest"
									 , "\(headers) (reqId:\(reqId)) --- error: \(err)")
			return (Data(), err)
		}
		if request.encodedData.count > self.handshake.MaxBytes {
			logger.Debug("Net[\(flag)]<\(connectID)>.send:MaxBytes"
									 , "\(headers) (reqId:\(reqId)) --- error: Too Large")
			return (Data(), .ElseErr("request.size(\(request.encodedData.count)) > MaxBytes(\(handshake.MaxBytes))"))
		}
		
		// 在客户端超时也认为是一个请求结束，但是真正的请求并没有结束，所以在服务器看来，仍然占用服务器的一个并发数
		// 因为网络异步的原因，客户端并发数不可能与服务器完全一样，所以这里主要是协助服务器做预控流，按照客户端的逻辑处理即可
		
		logger.Debug("Net[\(flag)]<\(connectID)>.send[\(reqId)]:request"
								 , "\(headers) (reqId:\(reqId))")
		
		let ch = await allRequests.Add(reqId: reqId)
		let ret2 = await WithTimeout(timeout) {
			Task {
				let err = await self.proto.Send(content:request.encodedData)
				if let err {
					await self.allRequests.Remove(reqId: reqId)?.Send((FakeHttp.Response(), err))
				}
			}
			
			if let r = await ch.Receive() {
				return r
			}
			return (FakeHttp.Response(), StmError.ElseErr("channel is closed, exception!!!"))
		}
		
		// timeout: ret2 == nil
		guard let ret2 else {
			logger.Debug("Net[\(flag)]<\(connectID)>.send[\(reqId)]:Timeout"
									 , "\(headers) (reqId:\(reqId)) --- timeout(>\(timeout.second())s)")
			return (Data(), .ElseTimeoutErr("request timeout(\(timeout.second())s)"))
		}
		
		if let err = ret2.1 {
			return (Data(), err)
		}
		
		logger.Debug("Net[\(flag)]<\(connectID)>.send[\(reqId)]:response"
								 , "\(headers) (reqId:\(reqId)) --- \(ret2.0.status)")
		
		if ret2.0.status != .OK {
			return (Data(),.ElseErr(String(decoding: ret2.0.data, as: UTF8.self)))
		}
		
		_ = await allRequests.Remove(reqId: reqId)
		
		return (ret2.0.data, nil)
	}
	
	func close()async {
		let oldState = await closeAndOldState(err: .ElseErr("closed by self"))
		if oldState == .Connected {
			logger.Debug("Net[\(flag)]<\(connectID)>.close", "closed, become invalidated")
			await self.proto.Close()
		}
	}
}

// delegate
extension Net {
	func onMessage(_ msg: Data) async {
		let (response, err) = msg.Parse()
		if let err {
			logger.Debug("Net[\(flag)]<\(connectID)>.onMessage:parse", "error --- \(err)")
			await onError(err)
			return
		}
		
		if response.isPush {
			let (pushAck, err) = response.newPushAck()
			if let err {
				logger.Debug("Net[\(flag)]<\(connectID)>.onMessage:newPushAck", "error --- \(err)")
				await onError(err)
				return
			}
			
			async let _ = self.onPush(response.data)
			// ignore error
			async let _ = {
				let err = await proto.Send(content: pushAck)
				if let err {
					logger.Debug("Net[\(flag)]<\(connectID)>.onMessage:pushAck", "error --- \(err)")
				}
			}()
			return
		}
		
		let ch = await allRequests.Remove(reqId: response.reqId)
		guard let ch else {
			logger.Warning("Net[\(flag)]<\(connectID)>.onMessage:NotFind"
										 , "warning: not find request for reqId(\(response.reqId)")
			return
		}
		
		logger.Debug("Net[\(flag)]<\(connectID)>.onMessage:response", "reqId=\(response.reqId)")
		async let _ = ch.Send((response, nil))
	}
	
	func onError(_ err: StmError) async {
		let oldState = await closeAndOldState(err: err)
		if oldState == .Connected {
			async let _ = {
				logger.Debug("Net[\(flag)]<\(connectID)>.onError:onPeerClosed", "\(err)")
				await self.onPeerClosed(err)
			}()

			await self.proto.Close()
		}
	}
}
