//
//  LogCapture.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CocoaLumberjackSwift
import Foundation
import os
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// Captures the messages of `CloudAccessDDLog` with debug logging enabled, until `stop()` is called.
///
/// `@unchecked Sendable`: restates the conformance of `DDAbstractLogger`; the added state is a lock and an immutable log level.
final class LogCapture: DDAbstractLogger, @unchecked Sendable {
	private let capturedMessages = OSAllocatedUnfairLock(initialState: [String]())
	private let previousLogLevel = dynamicCloudAccessLogLevel

	static func start() -> LogCapture {
		let capture = LogCapture()
		dynamicCloudAccessLogLevel = .debug
		CloudAccessDDLog.shared.add(capture)
		return capture
	}

	/// The messages logged so far, after all asynchronously logged messages were processed.
	var messages: [String] {
		CloudAccessDDLog.shared.flushLog()
		return capturedMessages.withLock { $0 }
	}

	var joinedMessages: String {
		return messages.joined(separator: "\n")
	}

	func stop() {
		CloudAccessDDLog.shared.remove(self)
		dynamicCloudAccessLogLevel = previousLogLevel
	}

	override func log(message logMessage: DDLogMessage) {
		capturedMessages.withLock { $0.append(logMessage.message) }
	}
}
