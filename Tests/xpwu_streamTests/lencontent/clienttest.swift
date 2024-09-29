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
		return Client.WithLenContent(.Host(properties.Host()), .Port(properties.Port()), logger:PrintLogger())
	}
	
	func noConnClient()-> Client {
		return Client.WithLenContent(.Host("10.0.0.0"), .Port(0), logger:PrintLogger())
	}

	func testNew() throws {
		_ = client()
	}
	
	func testClose()async throws {
		await client().Close()
	}
	
	func sendErr() async throws {
		let client = noConnClient()
//		let ret = await client.Send("{}".data(using: .utf8), withheaders: ["api":"/mega"])
		
	}

}
