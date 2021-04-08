//
//  GoogleDriveIdentifierCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class GoogleDriveIdentifierCacheTests: XCTestCase {
	var identifierCache: GoogleDriveIdentifierCache!
	override func setUpWithError() throws {
		guard let cache = GoogleDriveIdentifierCache() else {
			throw NSError(domain: "CryptomatorCloudAccess-Tests", code: -1000, userInfo: ["localizedDescription": "could not initialize GoogleDriveIdentifierCache"])
		}
		identifierCache = cache
	}

	override func tearDownWithError() throws {
		// Put teardown code here. This method is called after the invocation of each test method in the class.
	}

	func testRootIdentifierIsCachedAtStart() throws {
		let rootCloudPath = CloudPath("/")
		let rootIdentifier = identifierCache.getCachedIdentifier(for: rootCloudPath)
		XCTAssertNotNil(rootIdentifier)
		XCTAssertEqual("root", rootIdentifier)
	}

	func testCacheAndRetrieveIdentifierForFileCloudPath() throws {
		let identifierToStore = "TestABC--1234@^"
		let cloudPath = CloudPath("/abc/test.txt")
		try identifierCache.addOrUpdateIdentifier(identifierToStore, for: cloudPath)
		let retrievedIdentifier = identifierCache.getCachedIdentifier(for: cloudPath)
		XCTAssertNotNil(retrievedIdentifier)
		XCTAssertEqual(identifierToStore, retrievedIdentifier)
	}

	func testCacheAndRetrieveIdentifierForFolderCloudPath() throws {
		let identifierToStore = "TestABC--1234@^"
		let cloudPath = CloudPath("/abc/test--a-/")
		try identifierCache.addOrUpdateIdentifier(identifierToStore, for: cloudPath)
		let retrievedIdentifier = identifierCache.getCachedIdentifier(for: cloudPath)
		XCTAssertNotNil(retrievedIdentifier)
		XCTAssertEqual(identifierToStore, retrievedIdentifier)
	}

	func testUpdateWithDifferentIdentifierForCachedCloudPath() throws {
		let identifierToStore = "TestABC--1234@^"
		let cloudPath = CloudPath("/abc/test--a-/")
		try identifierCache.addOrUpdateIdentifier(identifierToStore, for: cloudPath)
		let newIdentifierToStore = "NewerIdentifer879978123.1-"
		try identifierCache.addOrUpdateIdentifier(newIdentifierToStore, for: cloudPath)
		let retrievedIdentifier = identifierCache.getCachedIdentifier(for: cloudPath)
		XCTAssertNotNil(retrievedIdentifier)
		XCTAssertEqual(newIdentifierToStore, retrievedIdentifier)
	}

	func testUnaddOrUpdateIdentifier() throws {
		let identifierToStore = "TestABC--1234@^"
		let cloudPath = CloudPath("/abc/test--a-/")
		try identifierCache.addOrUpdateIdentifier(identifierToStore, for: cloudPath)
		let retrievedIdentifier = identifierCache.getCachedIdentifier(for: cloudPath)
		XCTAssertNotNil(retrievedIdentifier)
		let secondCloudPath = CloudPath("/test/AAAAAAAAAAAA/test.txt")
		let secondIdentifierToStore = "SecondIdentifer@@^1!!´´$"
		try identifierCache.addOrUpdateIdentifier(secondIdentifierToStore, for: secondCloudPath)
		try identifierCache.invalidateIdentifier(for: cloudPath)
		XCTAssertNil(identifierCache.getCachedIdentifier(for: cloudPath))
		let stillCachedIdentifier = identifierCache.getCachedIdentifier(for: secondCloudPath)
		XCTAssertNotNil(stillCachedIdentifier)
		XCTAssertEqual(secondIdentifierToStore, stillCachedIdentifier)
	}

	func testUncacheCanBeCalledForNonExistentCloudPathsWithoutError() throws {
		let cloudPath = CloudPath("/abc/test--a-/")
		XCTAssertNil(identifierCache.getCachedIdentifier(for: cloudPath))
		try identifierCache.invalidateIdentifier(for: cloudPath)
	}
}
