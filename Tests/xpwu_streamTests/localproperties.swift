//
//  File.swift
//  
//
//  Created by xpwu on 2024/9/29.
//

import Foundation

private let file = URL(fileURLWithPath: #file).deletingLastPathComponent().appending(path: "local.properties")
private let hostKey = "lencontent.host"
private let portKey = "lencontent.port"
private let urlKey = "websocket.url"


/**
 
 file:  ./local.properties
 
 ```
 lencontent.host = xxx.xxx.xxx.xx
 
 lencontent.port = xxxx
 
 websocket.url = ws://xxxxxx
 
 ```
 */


func parsePropertiesFile(at fileURL: URL) -> [String: String] {
		guard let data = try? Data(contentsOf: fileURL),
					let content = String(data: data, encoding: .utf8) else {
			fatalError("not exist file: \(fileURL)")
		}
 
		var properties = [String: String]()
		content.components(separatedBy: .newlines).forEach { line in
				let pair = line.components(separatedBy: "=")
				if pair.count == 2 {
						properties[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
				}
		}
 
		return properties
}

class LocalProperties {
	
	var properties: [String:String] = parsePropertiesFile(at: file)
	
}

extension LocalProperties {
	func Host() ->String  {
		if properties[hostKey] == nil {
			fatalError("not exist key: `lencontent.host` in \(file)")
		}
		return properties[hostKey]!
	}
	
	func Port() ->Int  {
		if properties[portKey] == nil {
			fatalError("not exist key: `lencontent.host` in \(file)")
		}
		return Int(properties[portKey]!, radix: 10)!
	}
	
	func url() ->String  {
		if properties[urlKey] == nil {
			fatalError("not exist key: `lencontent.host` in \(file)")
		}
		return properties[urlKey]!
	}
}

