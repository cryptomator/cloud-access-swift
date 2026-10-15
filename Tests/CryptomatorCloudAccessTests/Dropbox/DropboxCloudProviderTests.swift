//
//  DropboxCloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import SwiftyDropbox
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxCloudProviderTests: XCTestCase {
	var provider: DropboxCloudProvider!

	override func setUpWithError() throws {
		DropboxSetup.constants = DropboxSetup(appKey: "", sharedContainerIdentifier: "", keychainService: "", forceForegroundSession: true)
		let credential = DropboxCredential(tokenUID: "testToken")
		provider = DropboxCloudProvider(credential: credential)
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	func testConvertCallErrorWithCancelledRequest() {
		let callError = CallError<Void>.clientError(.urlSessionError(URLError(.cancelled)))
		XCTAssertTrue(callError.converted() is CancellationError)
	}

	func testTransferProgressStartsOverForRetry() {
		let progress = Progress(totalUnitCount: 1)
		let phases = Progress.phases(of: progress, 999)
		let transferProgress = TransferProgress(phases[0])
		let firstAttempt = transferProgress.startAttempt()
		firstAttempt(100, 100)
		let secondAttempt = transferProgress.startAttempt()
		XCTAssertEqual(0, progress.fractionCompleted)
		firstAttempt(100, 100)
		XCTAssertEqual(0, progress.fractionCompleted)
		secondAttempt(50, 100)
		XCTAssertEqual(0.999 * 50 / 101, progress.fractionCompleted, accuracy: 0.0001)
		secondAttempt(100, 100)
		XCTAssertEqual(0.999 * 100 / 101, progress.fractionCompleted, accuracy: 0.0001)
		XCTAssertFalse(progress.isFinished)
		phases.completeTransfer()
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(progress.isFinished)
	}

	func testTransferProgressNeverFinishesFromByteCounts() throws {
		let progress = Progress(totalUnitCount: 1)
		let phases = Progress.phases(of: progress, 999)
		let transferChild = try XCTUnwrap(phases[0])
		let reportBytes = TransferProgress(transferChild).startAttempt()
		reportBytes(150, 100)
		XCTAssertFalse(transferChild.isFinished)
		XCTAssertEqual(0.999 * 100 / 101, progress.fractionCompleted, accuracy: 0.0001)
		reportBytes(10, -1)
		XCTAssertFalse(transferChild.isFinished)
	}
}
