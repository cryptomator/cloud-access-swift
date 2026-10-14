//
//  GoogleDriveCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 11.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class GoogleDriveCloudProviderTests: XCTestCase {
	var provider: GoogleDriveCloudProvider!

	override func setUpWithError() throws {
		GoogleDriveSetup.constants = GoogleDriveSetup(clientId: "", redirectURL: URL(string: "https://example.com")!, sharedContainerIdentifier: "")
		let credential = GoogleDriveCredential()
		provider = try GoogleDriveCloudProvider(credential: credential)
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	func testConvertErrorWithCancelledRequest() {
		let cancellationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
		let wrappedCancellationError = NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: cancellationError])
		XCTAssertTrue(provider.convertQueryError(cancellationError) is CancellationError)
		XCTAssertTrue(provider.convertQueryError(wrappedCancellationError) is CancellationError)
		XCTAssertTrue(provider.convertFetcherError(cancellationError) is CancellationError)
		XCTAssertTrue(provider.convertFetcherError(wrappedCancellationError) is CancellationError)
	}

	func testOnlyItemNameChangedWorksWithFolders() {
		let oldCloudPath = CloudPath("/AAAAAA/BBBBBBB")
		let newCloudPathOnlyFolderNameChanged = CloudPath("/AAAAAA/CCCCCCC")
		XCTAssertTrue(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathOnlyFolderNameChanged))

		let newCloudPathWithParentFolderChanged = CloudPath("/DDDDDDD/BBBBBBB")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithParentFolderChanged))

		let newCloudPathParentFolderAndFolderNameChanged = CloudPath("/DDDDDDD/CCCCCCC")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathParentFolderAndFolderNameChanged))
	}

	func testOnlyItemNameChangedWorksWithFiles() {
		let oldCloudPath = CloudPath("/AAAAAA/test.txt")
		let newCloudPathOnlyFileNameChanged = CloudPath("/AAAAAA/renamedTest.txt")
		XCTAssertTrue(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathOnlyFileNameChanged))

		let newCloudPathWithChangedPath = CloudPath("/DDDDDDD/BBBBBBB/test.txt")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithChangedPath))

		let newCloudPathWithPathAndFileNameChanged = CloudPath("/DDDDDDD/CCCCCCC/renamedAgainTest.txt")
		XCTAssertFalse(provider.onlyItemNameChangedBetween(oldCloudPath, and: newCloudPathWithPathAndFileNameChanged))
	}
}
