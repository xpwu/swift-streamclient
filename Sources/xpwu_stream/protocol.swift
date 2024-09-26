//
//  File.swift
//  
//
//  Created by xpwu on 2024/9/26.
//

import Foundation
import xpwu_x

/**
 *
 * 上层的调用 Protocol 及响应 Delegate 的时序逻辑：
 *
 *                             +-----------------------------------+
 *                             |                                   |
 *                             |                                   v
 *     connect{1} --+--(true)--+---[.async]--->send{n} ------> close{1}
 *                  |          |                                   ^
 *           (false)|          |-------> onMessage                 |
 *                  |          |             |                     |
 *        <Unit>----+          |          (error) --- [.async] --->|
 *                             |                                   |
 *                             +--------> onError --- [.async] ----+
 *
 *
 *    Protocol.connect() 与 Protocol.close() 上层使用方确保只会调用 1 次
 *    Protocol.connect() 失败，不会请求/响应任何接口
 *    Protocol.send() 会异步并发地调用 n 次，Protocol.send() 执行的时长不会让调用方挂起等待
 *    在上层明确调用 Protocol.close() 后，才不会调用 Protocol.send()
 *    Delegate.onMessage() 失败 及 Delegate.onError() 会异步调用 Protocol.close()
 *
 *    连接成功后，任何不能继续通信的情况都以 Delegate.onError() 返回
 *    Delegate.close() 的调用不触发 Delegate.onError()
 *    Delegate.connect() 的错误不触发 Delegate.onError()
 *    Delegate.send() 仅返回本次 Delegate.send() 的错误，
 *       不是底层通信的错误，底层通信的错误通过 Delegate.onError() 返回
 *
 */

public struct Handshake {
	public var HearBeatTime: Duration = Duration.INFINITE
	public var FrameTimeout: Duration = Duration.INFINITE // 同一帧里面的数据超时
	public var MaxConcurrent: Int = Int.max // 一个连接上的最大并发
	public var MaxBytes: UInt64 = 10 * 1024 * 1024 // 一帧数据的最大字节数
	public var ConnectId: String = "---no_connectId---"
	
	public init(){}
}

public protocol `Protocol` {
	
	func Connect() async -> (Handshake, StmError?)
	func Close() async
	func Send(content: [Byte]) -> StmError?
	
	var logger: Logger {get set}
	
	// delegate
	var onMessage: ([Byte])async -> Void {get set}
	var onError: (StmError)async -> Void {get set}
}

extension Handshake: CustomStringConvertible {
	public var description: String {
		return """
handshake info: {ConnectId: \(self.ConnectId), MaxConcurrent: \(self.MaxConcurrent) \
, HearBeatTime: \(self.HearBeatTime), MaxBytes/frame: \(self.MaxBytes), FrameTimeout: \(self.FrameTimeout)}
"""
	}
}

extension Handshake {
	/**
	 * ```
	 * HeartBeat_s | FrameTimeout_s | MaxConcurrent | MaxBytes | connect id
	 * HeartBeat_s: 2 bytes, net order
	 * FrameTimeout_s: 1 byte
	 * MaxConcurrent: 1 byte
	 * MaxBytes: 4 bytes, net order
	 * connect id: 8 bytes, net order
	 * ```
	 */
	
	public static let StreamLen = 2 + 1 + 1 + 4 + 8
	
	public static func Parse(handshake: [Byte]) -> Handshake {
		assert(handshake.count >= StreamLen)
		
		var ret = Handshake()
		ret.HearBeatTime = handshake[0..<2].net2UInt64() * Duration.Second
		ret.FrameTimeout = UInt64(handshake[2]) * Duration.Second
		ret.MaxConcurrent = Int(handshake[3])
		ret.MaxBytes = handshake[4..<8].net2UInt64()
		ret.ConnectId = String(format: "%016llx", handshake[8...].net2UInt64())
		
		return ret
	}
}
