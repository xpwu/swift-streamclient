//
//  File.swift
//  
//
//  Created by xpwu on 2024/10/7.
//

import Foundation

actor ClosedBySelf {
	var bySelf: Bool = false
	
	var isTrue: Bool {
		get {bySelf}
	}
	
	func yes() {
		bySelf = true
	}
}
