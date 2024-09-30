//
//  sendunittest.swift
//  
//
//  Created by xpwu on 2024/9/30.
//

import XCTest
import xpwu_x
@testable import xpwu_stream

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
	var results: Set<String> {
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
		return Client.WithLenContent(.Host(properties.Host()), .Port(properties.Port()), logger:PrintLogger())
	}
	
	func testSendOne() async throws {
		let c = client()
		let req = ReturnReq(data: "dkjfeoxeoxoeyionxa;;'a")
		let (ret, err) = await c.SendWithReqId(try! JSONEncoder().encode(req), withheaders: ["api" : "return"])
		XCTAssertNil(err)
		let res = try! JSONDecoder().decode(ReturnRes.self, from: ret)
		XCTAssertEqual(res.ret, req.data)
	}

}
