//
//  clienttest.swift
//  
//
//  Created by xpwu on 2024/9/29.
//

import XCTest
import xpwu_x
@testable import xpwu_stream

final class clienttest: XCTestCase {

	override func setUpWithError() throws {
		// Put setup code here. This method is called before the invocation of each test method in the class.
	}

	override func tearDownWithError() throws {
		// Put teardown code here. This method is called after the invocation of each test method in the class.
	}

	func testExample() throws {
		// This is an example of a functional test case.
		// Use XCTAssert and related functions to verify your tests produce the correct results.
		// Any test you write for XCTest can be annotated as throws and async.
		// Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
		// Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
	}

	func testPerformanceExample() throws {
		// This is an example of a performance test case.
		self.measure {
				// Put the code you want to measure the time of here.
		}
	}
	
	let properties = LocalProperties()
	
	func client()-> Client {
		return Client.withLenContent(.Host(properties.Host()), .Port(properties.Port()), logger:PrintLogger())
	}
	
	func noConnClient()-> Client {
		return Client.withLenContent(.Host("10.0.0.0"), .Port(80), logger:PrintLogger())
	}

	func testNew() throws {
		_ = client()
	}
	
	func testClose()async throws {
		await client().Close()
	}
	
	func testRecoverErr()async throws {
		let client = noConnClient()
		let ret = await client.Recover()
		XCTAssertEqual(true, ret?.isConnErr)
	}
	
	func testRecover() async throws {
		let client = client()
		let ret = await client.Recover()
		XCTAssertNil(ret)
	}
	
	func testAsyncRecover() async throws {
		let client = client()
		async let t1 = client.Recover()
		async let t2 = client.Recover()
		async let t3 = client.Recover()
		async let t4 = client.Recover()
		async let t5 = client.Recover()
		async let t6 = client.Recover()
		async let t7 = client.Recover()
		async let t8 = client.Recover()
		async let t9 = client.Recover()
		let ret = await [t1, t2, t3, t4, t5, t6, t7, t8, t9]
		XCTAssertNil(ret[8])
	}
	
	func testAsyncRecoverErr() async throws {
		let client = noConnClient()
		async let t1 = client.Recover()
		async let t2 = client.Recover()
		async let t3 = client.Recover()
		async let t4 = client.Recover()
		async let t5 = client.Recover()
		async let t6 = client.Recover()
		async let t7 = client.Recover()
		async let t8 = client.Recover()
		async let t9 = client.Recover()
		let ret = await [t1, t2, t3, t4, t5, t6, t7, t8, t9]
		XCTAssertEqual(true, ret[8]?.isConnErr)
	}
	
	func testSendErr() async throws {
		let client = noConnClient()
		var ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
		XCTAssertEqual(true, ret.1?.isConnErr)
		ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
		XCTAssertEqual(true, ret.1?.isConnErr)
		ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
		XCTAssertEqual(true, ret.1?.isConnErr)
	}
	
	func testAsyncSendErr() async throws {
		let client = noConnClient()
		
		async let t1: Void = {()async->Void in
			let ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
			XCTAssertEqual(true, ret.1?.isConnErr)
		}()
		async let t2: Void = {()async->Void in
			let ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
			XCTAssertEqual(true, ret.1?.isConnErr)
		}()
		async let t3: Void = {()async->Void in
			let ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
			XCTAssertEqual(true, ret.1?.isConnErr)
		}()
		async let t4: Void = {()async->Void in
			let ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
			XCTAssertEqual(true, ret.1?.isConnErr)
		}()
		async let t5: Void = {()async->Void in
			let ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
			XCTAssertEqual(true, ret.1?.isConnErr)
		}()
		async let t6: Void = {()async->Void in
			let ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
			XCTAssertEqual(true, ret.1?.isConnErr)
		}()
		async let t7: Void = {()async->Void in
			let ret = await client.Send("{}".data(using: .utf8)!, withheaders: ["api":"/mega"])
			XCTAssertEqual(true, ret.1?.isConnErr)
		}()
		
		_ = await [t1, t2, t3, t4, t5, t6, t7]
	}
	
	func testRecoverClose() async throws {
		let client = client()
		let ret = await client.Recover()
		XCTAssertNil(ret)
		await client.Close()
	}

}
