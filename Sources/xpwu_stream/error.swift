//
//  error.swift
//  stream
//
//  Created by xpwu on 2021/3/25.
//

import Foundation

public enum StmError: Error {
	case ConnTimeoutErr(String), ElseConnErr(String), ElseTimeoutErr(String), ElseErr(String, cause: Error? = nil)
}

extension StmError {
	public var isConnErr: Bool {
		switch self {
		case .ConnTimeoutErr, .ElseConnErr:
			return true
		default:
			return false
		}
	}
	
	public var isTimeoutErr: Bool {
		switch self {
		case .ConnTimeoutErr, .ElseTimeoutErr:
			return true
		default:
			return false
		}
	}
	
	public var msg: String {
		switch self {
		case .ConnTimeoutErr(let msg), .ElseConnErr(let msg), .ElseTimeoutErr(let msg):
			return msg
		case let .ElseErr(msg, err):
			if let err {
				return "\(msg), caused by \(err)"
			}
			return msg
		}
	}
	
	public var toConnError: StmError {
		get {
			if self.isConnErr {
				return self
			}
			return .ElseConnErr(self.msg)
		}
	}
}

