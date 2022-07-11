//
//  LocalFileSystemProviderIntegrationTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 23.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Promises
import XCTest

class LocalFileSystemProviderIntegrationTests: CloudAccessIntegrationTest {
	static let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: LocalFileSystemProviderIntegrationTests.self)
	}

	override class func setUp() {
		integrationTestParentCloudPath = CloudPath("/iOS-IntegrationTests-Plain")
		setUpProvider = try? LocalFileSystemProvider(rootURL: rootURL)
		do {
			try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true, attributes: nil)
		} catch {
			classSetUpError = error
			return
		}
		super.setUp()
	}

	override class func tearDown() {
		super.tearDown()
		try? FileManager.default.removeItem(at: rootURL)
	}

	override func setUpWithError() throws {
		try super.setUpWithError()
		provider = try LocalFileSystemProvider(rootURL: LocalFileSystemProviderIntegrationTests.rootURL)
	}

	override func createLimitedCloudProvider() throws -> CloudProvider {
		return try LocalFileSystemProvider(rootURL: LocalFileSystemProviderIntegrationTests.rootURL, maxPageSize: maxPageSizeForLimitedCloudProvider)
	}
}
