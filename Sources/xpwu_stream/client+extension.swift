//
//  File.swift
//  
//
//  Created by xpwu on 2024/9/29.
//

import Foundation
import xpwu_x

// LenContent
public extension Client {
	static func WithLenContent(_ options: LenContent.Option..., logger: Logger = PrintLogger())->Client {
		return Client(logger) {
			return LenContent(options)
		}
	}
	
	func UpdateOptions(_ options: LenContent.Option...) {
		self.UpdateProtocol {
			return LenContent(options)
		}
	}
}

// Websocket
public extension Client {
	static func withWebSocket(_ options: WebSocket.Option..., logger: Logger = PrintLogger())->Client {
		return Client(logger) {
			return WebSocket(options)
		}
	}
	
	func UpdateOptions(_ options: WebSocket.Option...) {
		self.UpdateProtocol {
			return WebSocket(options)
		}
	}
}

public extension Client {
	
	private static let reqidKey: String = "X-Req-Id"
	
	func SendWithReqId(_ data: Data, withheaders headers:[String:String]
										 , timeout: Duration = 30*Duration.Second)async -> (Data, StmError?) {
		
		var newHeaders = headers
		newHeaders[Client.reqidKey] = UUID().uuidString
		
		return await self.Send(data, withheaders: newHeaders, timeout: timeout)
	}
}


