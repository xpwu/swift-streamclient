import XCTest
@testable import xpwu_stream

final class exampleTests: XCTestCase {
    func testExample() throws {
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest

        // Defining Test Cases and Test Methods
        // https://developer.apple.com/documentation/xctest/defining_test_cases_and_test_methods
    }
	
	func testError()async {
		print(StmError.ConnTimeoutErr("timeout > 5s"))
		print({()->String in "test auto called closure1"}())
		async let a = {()async->String in "test auto called closure2"}()
		print(await a)
	}
}
