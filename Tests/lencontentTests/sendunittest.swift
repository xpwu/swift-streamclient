//
//  sendunittest.swift
//  
//
//  Created by xpwu on 2024/9/30.
//

import XCTest
import xpwu_x
import xpwu_concurrency
import xpwu_stream

struct ReturnReq: Codable {
	var data: String = ""
}

struct ReturnRes: Codable {
	var ret: String = ""
}

struct PushReq: Codable {
	var times: Int = 0
	var prefix: String = ""
}

var checkSet: Set<String>?
extension PushReq {
	private var results: Set<String> {
		get {
			var r = Set<String>()
			for i in 0..<times {
				r.insert("\(prefix)-\(i)")
			}
			
			return r
		}
	}
	
	func check(str: String)-> Bool {
		if checkSet == nil {
			checkSet = self.results
		}
		return checkSet!.remove(str) != nil
	}
}


final class sendunittest: XCTestCase {
	
	let properties = LocalProperties()
	
	func client()-> Client {
		return Client.withLenContent(.Host(properties.Host()), .Port(properties.Port()), logger:PrintLogger())
	}
	
	func testSendOne() async throws {
		let c = client()
		let req = ReturnReq(data: "dkjfeoxeoxoeyionxa;;'a")
		let (ret, err) = await c.SendWithReqId(try! JSONEncoder().encode(req), withheaders: ["api" : "return"])
		XCTAssertNil(err)
		let res = try! JSONDecoder().decode(ReturnRes.self, from: ret)
		XCTAssertEqual(res.ret, req.data)
	}
	
	func testSendMore() async throws {
		let c = client()
		let cases = [
			"woenkx",
			"0000今天很好",
			"kajiwnckajie",
			"val req = ReturnRequest(it)",
			"xpwu.kt-streamclient"
		]
		
		_ = await withTaskGroup(of: Void.self) { group in
			_ = cases.map { acase in
				group.addTask {
					let req = ReturnReq(data: acase)
					let (ret, err) = await c.SendWithReqId(try! JSONEncoder().encode(req), withheaders: ["api":"return"])
					XCTAssertNil(err)
					let res = try! JSONDecoder().decode(ReturnRes.self, from: ret)
					XCTAssertEqual(res.ret, req.data)
				}
			}
			await group.waitForAll()
		}
	}
	
	func testSendClose() async throws {
		let c = client()
		let ch = Channel<Bool>(buffer: 0)
		c.onPeerClosed = { (_)async -> Void in
			_ = try? await ch.Send(true)
		}
		
		let (ret, err) = await c.SendWithReqId("{}".data(using: .utf8)!, withheaders: ["api":"close"])
		XCTAssertNil(err)
		XCTAssertEqual("{}", String(data: ret, encoding: .utf8))
		
		let rt = try await withTimeoutOrNil(5*Duration.Second) {
			try await ch.Receive()!
		}
		XCTAssertNotNil(rt, "timeout(5s): not receive onPeerClosed")
		XCTAssertTrue(rt!)
	}
	
	func testSendPush() async throws {
		let req = PushReq(times: 3, prefix: "this is a push test")
		let c = client()
		let ch = Channel<Bool>(buffer: req.times)
		c.onPush = {msg in
			print("on push : \(String(data: msg, encoding: .utf8)!)")
			_ = try? await ch.Send(req.check(str: String(data: msg, encoding: .utf8)!))
			if checkSet!.count == 0 {
				await ch.Close()
			}
		}
		
		let (ret, err) = await c.SendWithReqId(try! JSONEncoder().encode(req), withheaders: ["api":"PushLt20Times"])
		XCTAssertNil(err)
		XCTAssertEqual("{}", String(data: ret, encoding: .utf8))
		
		let rt = try await withTimeoutOrNil(30*Duration.Second) {
			while true {
				let r = try await ch.Receive()
				guard let r else {
					break
				}
				
				if !r {
					return false
				}
			}
			
			return true
		}
		
		XCTAssertNotNil(rt, "timeout(30s): not receive all onPush")
		XCTAssertTrue(rt!)
	}
}
