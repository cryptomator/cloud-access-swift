//
//  DirectoryContentCacheMock.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

// swiftlint:disable all
/// `@unchecked Sendable`: only used by the synchronous parser tests, which call it from a single thread.
final class DirectoryContentCacheMock: DirectoryContentCache, @unchecked Sendable {
	// MARK: - save

	var saveInIndexThrowableError: Error?
	var saveInIndexCallsCount = 0
	var saveInIndexCalled: Bool {
		saveInIndexCallsCount > 0
	}

	var saveInIndexReceivedArguments: (element: CloudItemMetadata, snapshot: DirectoryContentSnapshot, index: Int64)?
	var saveInIndexReceivedInvocations: [(element: CloudItemMetadata, snapshot: DirectoryContentSnapshot, index: Int64)] = []
	var saveInIndexClosure: ((CloudItemMetadata, DirectoryContentSnapshot, Int64) throws -> Void)?

	func save(_ element: CloudItemMetadata, in snapshot: DirectoryContentSnapshot, index: Int64) throws {
		if let error = saveInIndexThrowableError {
			throw error
		}
		saveInIndexCallsCount += 1
		saveInIndexReceivedArguments = (element: element, snapshot: snapshot, index: index)
		saveInIndexReceivedInvocations.append((element: element, snapshot: snapshot, index: index))
		try saveInIndexClosure?(element, snapshot, index)
	}

	// MARK: - discard

	var discardThrowableError: Error?
	var discardCallsCount = 0
	var discardCalled: Bool {
		discardCallsCount > 0
	}

	var discardReceivedSnapshot: DirectoryContentSnapshot?
	var discardReceivedInvocations: [DirectoryContentSnapshot] = []
	var discardClosure: ((DirectoryContentSnapshot) throws -> Void)?

	func discard(_ snapshot: DirectoryContentSnapshot) throws {
		if let error = discardThrowableError {
			throw error
		}
		discardCallsCount += 1
		discardReceivedSnapshot = snapshot
		discardReceivedInvocations.append(snapshot)
		try discardClosure?(snapshot)
	}

	// MARK: - publish

	var publishThrowableError: Error?
	var publishCallsCount = 0
	var publishCalled: Bool {
		publishCallsCount > 0
	}

	var publishReceivedSnapshot: DirectoryContentSnapshot?
	var publishReceivedInvocations: [DirectoryContentSnapshot] = []
	var publishReturnValue: CloudItemList!
	var publishClosure: ((DirectoryContentSnapshot) throws -> CloudItemList)?

	func publish(_ snapshot: DirectoryContentSnapshot) throws -> CloudItemList {
		if let error = publishThrowableError {
			throw error
		}
		publishCallsCount += 1
		publishReceivedSnapshot = snapshot
		publishReceivedInvocations.append(snapshot)
		return try publishClosure.map({ try $0(snapshot) }) ?? publishReturnValue
	}

	// MARK: - getPage

	var getPageForPageTokenThrowableError: Error?
	var getPageForPageTokenCallsCount = 0
	var getPageForPageTokenCalled: Bool {
		getPageForPageTokenCallsCount > 0
	}

	var getPageForPageTokenReceivedArguments: (folderPath: CloudPath, pageToken: String)?
	var getPageForPageTokenReceivedInvocations: [(folderPath: CloudPath, pageToken: String)] = []
	var getPageForPageTokenReturnValue: CloudItemList!
	var getPageForPageTokenClosure: ((CloudPath, String) throws -> CloudItemList)?

	func getPage(for folderPath: CloudPath, pageToken: String) throws -> CloudItemList {
		if let error = getPageForPageTokenThrowableError {
			throw error
		}
		getPageForPageTokenCallsCount += 1
		getPageForPageTokenReceivedArguments = (folderPath: folderPath, pageToken: pageToken)
		getPageForPageTokenReceivedInvocations.append((folderPath: folderPath, pageToken: pageToken))
		return try getPageForPageTokenClosure.map({ try $0(folderPath, pageToken) }) ?? getPageForPageTokenReturnValue
	}
}

// swiftlint:enable all
