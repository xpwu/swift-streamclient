//
//  File.swift
//  
//
//  Created by xpwu on 2024/9/26.
//

import Foundation
import xpwu_concurrency

private let reqIdStart: UInt64 = 10

private typealias RequestChannel = Channel<(FakeHttp.Response, StmError?)>

fileprivate class SyncAllRequest {
	let mutex: Mutex = Mutex()
	var allRequests: [UInt64:RequestChannel] = [:]
	var semaphore: xpwu_concurrency.Semaphore = Semaphore(permits: 3)
	
	public var permits: Int {
		get {semaphore.Permits}
		set {semaphore = Semaphore(permits: newValue)}
	}
	
	init(permits: Int = 3) {
		semaphore = Semaphore(permits: permits)
	}
}

extension SyncAllRequest {
	func Add(reqId: UInt64) async -> RequestChannel {
		await semaphore.Acquire()
		return await mutex.WithLock {
			let ch = RequestChannel(buffer: 1)
			allRequests[reqId] = ch
			return ch
		}
	}
	
	// 可以用同一个 reqid 重复调用
	func Remove(reqId: UInt64) async -> RequestChannel? {
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
 *    NotConnect  --->  Connecting  ---> Connected ---> Invalidated
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

class Net {
	
}
