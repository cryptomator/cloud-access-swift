//
//  TemporaryFileSupport.swift
//  CryptomatorCloudAccessTestSupport
//
//  Created by Tobias Hagemann on 27.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing

package func makeTemporaryDirectory() throws -> URL {
	let url = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString, directoryHint: .isDirectory)
	try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
	return url
}

/// Records a failed removal as an issue of the running test, so that a cleanup that can't throw, such as a suite's `deinit` or a `defer`, still fails the test.
package func removeItemRecordingFailure(at url: URL, sourceLocation: SourceLocation = #_sourceLocation) {
	do {
		try FileManager.default.removeItem(at: url)
	} catch {
		Issue.record(error, sourceLocation: sourceLocation)
	}
}
