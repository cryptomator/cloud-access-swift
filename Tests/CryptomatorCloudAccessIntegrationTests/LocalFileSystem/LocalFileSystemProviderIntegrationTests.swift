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
	static var setUpErrorForLocalFileSystem: Error?
	override class var classSetUpError: Error? {
		get {
			return setUpErrorForLocalFileSystem
		}
		set {
			setUpErrorForLocalFileSystem = newValue
		}
	}

	static let rootURLForIntegrationTestAtLocalFileSystem = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
	static let setUpProviderForLocalFileSystem = LocalFileSystemProvider(rootURL: rootURLForIntegrationTestAtLocalFileSystem)

	override class var setUpProvider: CloudProvider {
		return setUpProviderForLocalFileSystem
	}

	static let folderWhereTheIntegrationTestFolderIsCreatedAtLocalFileSystem = CloudPath("/IntegrationTest/")
	override class var folderWhereTheIntegrationTestFolderIsCreated: CloudPath {
		return folderWhereTheIntegrationTestFolderIsCreatedAtLocalFileSystem
	}

	// If you do not need to initialize anything special once or before the IntegrationTest setup, you can ignore this function.
	override class func setUp() {
		// It is very important to call super.setUp(), otherwise the IntegrationTest will not be built correctly.
		do {
			try FileManager.default.createDirectory(at: rootURLForIntegrationTestAtLocalFileSystem, withIntermediateDirectories: true, attributes: nil)
		} catch {
			classSetUpError = error
			return
		}
		super.setUp()
	}

	override func setUpWithError() throws {
		// This call is very important, otherwise errors from the IntegrationTest once setup will not be considered correctly.
		try super.setUpWithError()
		super.provider = LocalFileSystemProvider(rootURL: LocalFileSystemProviderIntegrationTests.rootURLForIntegrationTestAtLocalFileSystem)
	}

	override class var defaultTestSuite: XCTestSuite {
		return XCTestSuite(forTestCaseClass: LocalFileSystemProviderIntegrationTests.self)
	}
}
