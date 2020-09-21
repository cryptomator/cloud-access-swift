//
//  CryptorMock.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 10.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCryptoLib

class CryptoSupportMock: CryptoSupport {
	override func createRandomBytes(size: Int) throws -> [UInt8] {
		return [UInt8](repeating: 0xF0, count: size)
	}
}

extension Dictionary where Value: Equatable {
	func someKey(for value: Value) -> Key? {
		return first(where: { $1 == value })?.key
	}
}

enum CryptorMockError: Error {
	case notMocked
}

public class CryptorMock: Cryptor {
	let dirIds: [String: String]
	let fileNames: [String: String]
	let contents: [String: String]

	init(masterkey: Masterkey, dirIds: [String: String], fileNames: [String: String], contents: [String: String]) {
		self.dirIds = dirIds
		self.fileNames = fileNames
		self.contents = contents
		super.init(masterkey: masterkey, cryptoSupport: CryptoSupportMock())
	}

	override public func encryptDirId(_ dirId: Data) throws -> String {
		if let dirId = dirIds[String(data: dirId, encoding: .utf8)!] {
			return dirId
		} else {
			return "99ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
		}
	}

	override public func encryptFileName(_ cleartextName: String, dirId: Data, encoding: FileNameEncoding = .base64url) throws -> String {
		if let ciphertextName = fileNames.someKey(for: cleartextName) {
			return ciphertextName
		} else {
			throw CryptorMockError.notMocked
		}
	}

	override public func decryptFileName(_ ciphertextName: String, dirId: Data, encoding: FileNameEncoding = .base64url) throws -> String {
		if let cleartextName = fileNames[ciphertextName] {
			return cleartextName
		} else {
			throw CryptorMockError.notMocked
		}
	}

	override public func encryptContent(from cleartextURL: URL, to ciphertextURL: URL) throws {
		let cleartext = try String(contentsOf: cleartextURL, encoding: .utf8)
		if let ciphertext = contents.someKey(for: cleartext) {
			try ciphertext.write(to: ciphertextURL, atomically: true, encoding: .utf8)
		} else {
			throw CryptorMockError.notMocked
		}
	}

	override public func decryptContent(from ciphertextURL: URL, to cleartextURL: URL) throws {
		let ciphertext = try String(contentsOf: ciphertextURL, encoding: .utf8)
		if let cleartext = contents[ciphertext] {
			try cleartext.write(to: cleartextURL, atomically: true, encoding: .utf8)
		} else {
			throw CryptorMockError.notMocked
		}
	}

	override public func calculateCiphertextSize(_ cleartextSize: Int) -> Int {
		return 0
	}

	override public func calculateCleartextSize(_ ciphertextSize: Int) throws -> Int {
		return 0
	}
}
