//
//  XCTAssertThrowsError+Async.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 13.04.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest

public func XCTAssertThrowsErrorAsync<T>(
	_ expression: @autoclosure () async throws -> T,
	_ message: @autoclosure () -> String = "",
	file: StaticString = #filePath,
	line: UInt = #line,
	_ errorHandler: (_ error: any Error) -> Void = { _ in }
) async {
	do {
		_ = try await expression()
		XCTFail(message(), file: file, line: line)
	} catch {
		errorHandler(error)
	}
}
