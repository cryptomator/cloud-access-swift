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
final class DirectoryContentCacheMock: DirectoryContentCache {
	// MARK: - save

	var saveForIndexThrowableError: Error?
	var saveForIndexCallsCount = 0
	var saveForIndexCalled: Bool {
		saveForIndexCallsCount > 0
	}

	var saveForIndexReceivedArguments: (element: CloudItemMetadata, folderEnumerationPath: CloudPath, index: Int64)?
	var saveForIndexReceivedInvocations: [(element: CloudItemMetadata, folderEnumerationPath: CloudPath, index: Int64)] = []
	var saveForIndexClosure: ((CloudItemMetadata, CloudPath, Int64) throws -> Void)?

	func save(_ element: CloudItemMetadata, for folderEnumerationPath: CloudPath, index: Int64) throws {
		if let error = saveForIndexThrowableError {
			throw error
		}
		saveForIndexCallsCount += 1
		saveForIndexReceivedArguments = (element: element, folderEnumerationPath: folderEnumerationPath, index: index)
		saveForIndexReceivedInvocations.append((element: element, folderEnumerationPath: folderEnumerationPath, index: index))
		try saveForIndexClosure?(element, folderEnumerationPath, index)
	}

	// MARK: - clearCache

	var clearCacheForThrowableError: Error?
	var clearCacheForCallsCount = 0
	var clearCacheForCalled: Bool {
		clearCacheForCallsCount > 0
	}

	var clearCacheForReceivedFolderEnumerationPath: CloudPath?
	var clearCacheForReceivedInvocations: [CloudPath] = []
	var clearCacheForClosure: ((CloudPath) throws -> Void)?

	func clearCache(for folderEnumerationPath: CloudPath) throws {
		if let error = clearCacheForThrowableError {
			throw error
		}
		clearCacheForCallsCount += 1
		clearCacheForReceivedFolderEnumerationPath = folderEnumerationPath
		clearCacheForReceivedInvocations.append(folderEnumerationPath)
		try clearCacheForClosure?(folderEnumerationPath)
	}

	// MARK: - getResponse

	var getResponseForPageTokenThrowableError: Error?
	var getResponseForPageTokenCallsCount = 0
	var getResponseForPageTokenCalled: Bool {
		getResponseForPageTokenCallsCount > 0
	}

	var getResponseForPageTokenReceivedArguments: (folderPath: CloudPath, pageToken: String?)?
	var getResponseForPageTokenReceivedInvocations: [(folderPath: CloudPath, pageToken: String?)] = []
	var getResponseForPageTokenReturnValue: DirectoryContentCacheResponse!
	var getResponseForPageTokenClosure: ((CloudPath, String?) throws -> DirectoryContentCacheResponse)?

	func getResponse(for folderPath: CloudPath, pageToken: String?) throws -> DirectoryContentCacheResponse {
		if let error = getResponseForPageTokenThrowableError {
			throw error
		}
		getResponseForPageTokenCallsCount += 1
		getResponseForPageTokenReceivedArguments = (folderPath: folderPath, pageToken: pageToken)
		getResponseForPageTokenReceivedInvocations.append((folderPath: folderPath, pageToken: pageToken))
		return try getResponseForPageTokenClosure.map({ try $0(folderPath, pageToken) }) ?? getResponseForPageTokenReturnValue
	}
}

// swiftlint:enable all
