//
//  CryptorMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 10.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import CryptomatorCryptoLib
import Foundation
import os
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

extension Dictionary where Value: Equatable {
	func someKey(for value: Value) -> Key? {
		return first(where: { $1 == value })?.key
	}
}

enum CryptorMockError: Error {
	case notMocked
}

/// `@unchecked Sendable`: `dirIds`, `fileNames`, `contents` and `fileHeaderSize` are immutable, everything else is protected by `hooks`. The class is subclassed by the vault format mocks.
public class CryptorMock: VaultCryptor, @unchecked Sendable {
	private struct Hooks {
		var decryptFileNameError: Error?
		var encryptContentHook: (@Sendable (_ cleartextURL: URL, _ ciphertextURL: URL) throws -> Void)?
		var decryptContentHook: (@Sendable (_ ciphertextURL: URL, _ cleartextURL: URL) throws -> Void)?
	}

	let dirIds: [String: String]
	let fileNames: [String: String]
	let contents: [String: String]
	public let fileHeaderSize = 0
	private let hooks = OSAllocatedUnfairLock(initialState: Hooks())

	var decryptFileNameError: Error? {
		get { hooks.withLock { $0.decryptFileNameError } }
		set { hooks.withLock { $0.decryptFileNameError = newValue } }
	}

	/// Runs in the calling task after the ciphertext was written.
	var encryptContentHook: (@Sendable (_ cleartextURL: URL, _ ciphertextURL: URL) throws -> Void)? {
		get { hooks.withLock { $0.encryptContentHook } }
		set { hooks.withLock { $0.encryptContentHook = newValue } }
	}

	/// Runs in the calling task after the cleartext was written.
	var decryptContentHook: (@Sendable (_ ciphertextURL: URL, _ cleartextURL: URL) throws -> Void)? {
		get { hooks.withLock { $0.decryptContentHook } }
		set { hooks.withLock { $0.decryptContentHook = newValue } }
	}

	init(dirIds: [String: String], fileNames: [String: String], contents: [String: String]) {
		self.dirIds = dirIds
		self.fileNames = fileNames
		self.contents = contents
	}

	public func encryptDirId(_ dirId: Data) throws -> String {
		if let dirId = dirIds[String(data: dirId, encoding: .utf8)!] {
			return dirId
		} else {
			return "99ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"
		}
	}

	public func encryptFileName(_ cleartextName: String, dirId: Data, encoding: FileNameEncoding) throws -> String {
		if let ciphertextName = fileNames.someKey(for: cleartextName) {
			return ciphertextName
		} else {
			throw CryptorMockError.notMocked
		}
	}

	public func decryptFileName(_ ciphertextName: String, dirId: Data, encoding: FileNameEncoding) throws -> String {
		if let decryptFileNameError {
			throw decryptFileNameError
		}
		if let cleartextName = fileNames[ciphertextName] {
			return cleartextName
		} else {
			throw CryptorMockError.notMocked
		}
	}

	@concurrent
	public func encryptContent(from cleartextURL: URL, to ciphertextURL: URL, progress: Progress?) async throws {
		let cleartext = try String(contentsOf: cleartextURL, encoding: .utf8)
		if let ciphertext = contents.someKey(for: cleartext) {
			try ciphertext.write(to: ciphertextURL, atomically: true, encoding: .utf8)
		} else {
			try "some-encrypted-content".write(to: ciphertextURL, atomically: true, encoding: .utf8)
		}
		progress?.completedUnitCount = progress?.totalUnitCount ?? 0
		try encryptContentHook?(cleartextURL, ciphertextURL)
	}

	@concurrent
	public func decryptContent(from ciphertextURL: URL, to cleartextURL: URL, progress: Progress?) async throws {
		let ciphertext = try String(contentsOf: ciphertextURL, encoding: .utf8)
		if let cleartext = contents[ciphertext] {
			try cleartext.write(to: cleartextURL, atomically: true, encoding: .utf8)
		} else {
			throw CryptorMockError.notMocked
		}
		progress?.completedUnitCount = progress?.totalUnitCount ?? 0
		try decryptContentHook?(ciphertextURL, cleartextURL)
	}

	public func calculateCiphertextSize(_ cleartextSize: Int) -> Int {
		precondition(cleartextSize >= 0, "expected cleartextSize to be positive, but was \(cleartextSize)")
		return 0
	}

	public func calculateCleartextSize(_ ciphertextSize: Int) throws -> Int {
		precondition(ciphertextSize >= 0, "expected ciphertextSize to be positive, but was \(ciphertextSize)")
		return 0
	}
}
