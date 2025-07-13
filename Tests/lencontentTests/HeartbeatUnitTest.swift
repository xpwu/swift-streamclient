//
//  HeartbeatUnitTest.swift
//  
//
//  Created by xpwu on 2024/10/7.
//

import XCTest
import xpwu_x
import xpwu_concurrency
@testable import xpwu_stream

final class HBLogger: @unchecked Sendable {
	
	let hbTimeRegex = try! NSRegularExpression(pattern: "^LenContent\\[.*]<.*>.readHandshake:handshake$")
	let hbTimeResult = try! NSRegularExpression(pattern: "^handshake info: \\{ConnectId: .*, MaxConcurrent: .*, HearBeatTime: (.*), MaxBytes/frame: .*, FrameTimeout: .*\\}$")
	let sendRegex = try! NSRegularExpression(pattern: "^LenContent\\[.*]<.*>.outputHeartbeat:send$")
	let recRegex = try! NSRegularExpression(pattern: "^LenContent\\[.*]<.*>.read:Heartbeat$")
	
	let printLogger = PrintLogger()
	
	var hbTime:Duration = 0
	let recHbCh = Channel<Bool>(buffer: Int.Unlimited)
	var send:()->Void = {}
	
}

extension HBLogger: Logger {
	func OutPut(type: xpwu_x.LoggerType, tag: () -> String, msg: () -> String, file: String, line: Int) {
		if type != .Debug {
			printLogger.OutPut(type: type, tag: tag, msg: msg, file: file, line: line)
			return
		}
		
		if sendRegex.numberOfMatches(tag()) > 0 {
			send()
		}
		if recRegex.numberOfMatches(tag()) > 0 {
			Task {
				try! await recHbCh.Send(true)
			}
		}
		if hbTimeRegex.numberOfMatches(tag()) > 0 {
			if let ret = hbTimeResult.firstMatch(msg()) {
				if ret.count == 2 {
					hbTime = .from(string: ret.string(at: 1)) ?? 0
				}
			}
		}
		
		printLogger.OutPut(type: type, tag: tag, msg: msg, file: file, line: line)
	}
}

final class HeartbeatUnitTest: XCTestCase {
	let properties = LocalProperties()
	
	func client(_ logger: Logger)-> Client {
		return Client.withLenContent(.Host(properties.Host()), .Port(properties.Port()), logger: logger)
	}
	
	func testHBtime() async throws {
		let logger = HBLogger()
		let c = client(logger)
		let ret = await c.Recover()
		XCTAssertNil(ret)
		XCTAssertNotEqual(0, logger.hbTime)
		await c.Close()
	}
	
	func testSendHB() async throws {
		let logger = HBLogger()
		let ch = Channel<Bool>()
		logger.send = {
			Task {
				_ = try await ch.Send(true)
			}
		}
		
		let c = client(logger)
		c.onPeerClosed = {err ->Void in
			_ = try! await ch.Send(false)
		}
		let ret = await c.Recover()
		XCTAssertNil(ret)
		XCTAssertNotEqual(0, logger.hbTime)
		
		// first
		var rec = try! await withTimeoutOrNil(logger.hbTime + 5*Duration.Second) {
			try (await ch.Receive())!
		}
		// timeout
		XCTAssertNotNil(rec, "timeout: not send heartbeat(\(logger.hbTime))")
		XCTAssertTrue(rec!, "peer closed: not send heartbeat(\(logger.hbTime))")
		
		// second
		rec = try! await withTimeoutOrNil(logger.hbTime + 5*Duration.Second) {
			try (await ch.Receive())!
		}
		// timeout
		XCTAssertNotNil(rec, "timeout: not send heartbeat(\(logger.hbTime))")
		XCTAssertTrue(rec!, "peer closed: not send heartbeat(\(logger.hbTime))")
		
		// third
		rec = try! await withTimeoutOrNil(logger.hbTime + 5*Duration.Second) {
			try (await ch.Receive())!
		}
		// timeout
		XCTAssertNotNil(rec, "timeout: not send heartbeat(\(logger.hbTime))")
		XCTAssertTrue(rec!, "peer closed: not send heartbeat(\(logger.hbTime))")
		
		await c.Close()
	}
	
	func testRecHB() async throws {
		let logger = HBLogger()

		let c = client(logger)
		c.onPeerClosed = {err ->Void in
			_ = try! await logger.recHbCh.Send(false)
		}
		let ret = await c.Recover()
		XCTAssertNil(ret)
		XCTAssertNotEqual(0, logger.hbTime)
		
		// first
		var rec = try! await withTimeoutOrNil(2*logger.hbTime) {
			try (await logger.recHbCh.Receive())!
		}
		// timeout
		XCTAssertNotNil(rec, "timeout: not receive heartbeat(\(logger.hbTime))")
		XCTAssertTrue(rec!, "peer closed: not receive heartbeat(\(logger.hbTime))")
		
		// second
		rec = try! await withTimeoutOrNil(logger.hbTime + 5*Duration.Second) {
			try (await logger.recHbCh.Receive())!
		}
		// timeout
		XCTAssertNotNil(rec, "timeout: not receive heartbeat(\(logger.hbTime))")
		XCTAssertTrue(rec!, "peer closed: not receive heartbeat(\(logger.hbTime))")
		
		// third
		rec = try! await withTimeoutOrNil(logger.hbTime + 5*Duration.Second) {
			try (await logger.recHbCh.Receive())!
		}
		// timeout
		XCTAssertNotNil(rec, "timeout: not receive heartbeat(\(logger.hbTime))")
		XCTAssertTrue(rec!, "peer closed: not receive heartbeat(\(logger.hbTime))")
		
		await c.Close()
	}
}
