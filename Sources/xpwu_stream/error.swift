//
//  error.swift
//  stream
//
//  Created by xpwu on 2021/3/25.
//

import Foundation

public enum StmError: Error {
	case ConnTimeoutErr(String), ElseConnErr(String), ElseTimeoutErr(String), ElseErr(String)
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
		case .ConnTimeoutErr(let msg), .ElseConnErr(let msg), .ElseTimeoutErr(let msg), .ElseErr(let msg):
			return msg
		}
	}
}

