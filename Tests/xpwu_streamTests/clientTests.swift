import XCTest
@testable import xpwu_stream

final class streamclientTests: XCTestCase {
    func testExample() throws {
        // XCTest Documentation
        // https://developer.apple.com/documentation/xctest

        // Defining Test Cases and Test Methods
        // https://developer.apple.com/documentation/xctest/defining_test_cases_and_test_methods
    }
	
	func testError() {
		print(StmError.ConnTimeoutErr("timeout > 5s"))
	}
}
