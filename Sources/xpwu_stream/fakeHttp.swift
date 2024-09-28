//
//  fakeHttp.swift
//  stream
//
//  Created by xpwu on 2021/3/24.
//

import Foundation
import xpwu_x

/**

content protocol:
     request ---
       reqid | headers | header-end-flag | data
         reqid: 4 bytes, net order;
         headers: < key-len | key | value-len | value > ... ;  [optional]
           key-len: 1 byte,  key-len = sizeof(key);
           value-len: 1 byte, value-len = sizeof(value);
         header-end-flag: 1 byte, === 0;
         data:       [optional]

    reqid = 1: client push ack to server.
          ack: no headers;
          data: pushId. 4 bytes, net order;

  ---------------------------------------------------------------------
     response ---
       reqid | status | data
         reqid: 4 bytes, net order;
         status: 1 byte, 0---success, 1---failed
         data: if status==success, data=<app data>    [optional]
               if status==failed, data=<error reason>


     reqid = 1: server push to client
        status: 0
        data: first 4 bytes --- pushId, net order;
              last --- real data

*/


struct FakeHttp{
  struct Request {
		fileprivate var data:[Byte] = []
		var encodedData: [Byte] { get {data} }
		
		mutating func setReqId(reqId:UInt32) {
      data[0] = Byte((reqId & 0xff000000) >> 24)
      data[1] = Byte((reqId & 0xff0000) >> 16)
      data[2] = Byte((reqId & 0xff00) >> 8)
      data[3] = Byte(reqId & 0xff)
    }
  }
  
  struct Response {
    enum Status {
      case OK
      case Failed
    }
		
		var status: Status = .Failed
		var reqId: UInt32 = 0
		var data: [Byte] = []
		var pushID: [Byte] = []
		
		var isPush: Bool {
			reqId == 1
		}
  }
	
	static let OK = Response.Status.OK
	static let Failed = Response.Status.Failed
}

extension FakeHttp.Request {
	static func New(reqId: UInt32, body:[Byte], headers:[String:String]) -> (FakeHttp.Request, StmError?) {
		var req = FakeHttp.Request()
		// reqid
		req.data = [Byte](repeating: 0, count: 4)
		req.setReqId(reqId: reqId)
		
		for (key, value) in headers {
			let k = key.utf8
			let v = value.utf8
			if (k.count > 255 || v.count > 255) {
				return (req, StmError.ElseErr("key(\(key))'s length or value(\(value))'s length is more than 255"))
			}
			req.data.append(Byte(k.count))
			req.data.append(contentsOf: k)
			req.data.append(Byte(v.count))
			req.data.append(contentsOf: v)
		}
		
		// end-of-headers
		req.data.append(0)
		
		req.data.append(contentsOf: body)
		
		return (req, nil)
	}
}

extension FakeHttp.Response {
	func newPushAck() -> ([Byte], StmError?) {
		if (!isPush || pushID.count != 4) {
			return ([], .ElseErr("invalid push data"))
		}
		
		var ret = [Byte](repeating: 0, count: 4)
		ret[0] = Byte((reqId & 0xff000000) >> 24)
		ret[1] = Byte((reqId & 0xff0000) >> 16)
		ret[2] = Byte((reqId & 0xff00) >> 8)
		ret[3] = Byte(reqId & 0xff)
		
		// end-of-headers
		ret.append(0)
		
		ret.append(contentsOf: pushID)
		
		return (ret, nil)
	}
}

extension Array where Element == Byte {
	func Parse() -> (FakeHttp.Response, StmError?) {
		var res = FakeHttp.Response()
		
		if self.count < 5 {
			return (res, StmError.ElseErr("fakehttp protocol err(response.size < 5)."))
		}
		
		res.status = self[4]==0 ? FakeHttp.Response.Status.OK : FakeHttp.Response.Status.Failed
		
		res.reqId = 0
		for i in 0..<4 {
			res.reqId = UInt32(res.reqId << 8) + UInt32(self[i] & 0xff)
		}
		
		var offset = 5
		// push
		if res.reqId == 1 {
			if self.count < offset + 4 {
				return (res, StmError.ElseErr("fakehttp protocol err(response.size of push < 9)."))
			}
			
			res.pushID = [Byte](self[offset..<offset+4])
			offset += 4
		}
		
		if (self.count <= offset) {
			res.data = []
		} else {
			res.data = [Byte](self[offset...])
		}
		
		return (res, nil)
	}
}
