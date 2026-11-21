//
//  Date+ISO8601.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os

private extension ISO8601DateFormatter {
	static func fractionalSecondsFormatter() -> ISO8601DateFormatter {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}
}

extension Date {
	/// Unlike `DateFormatter`, `ISO8601DateFormatter` isn't documented as thread-safe.
	private static let iso8601Formatters = OSAllocatedUnfairLock(uncheckedState: (plain: ISO8601DateFormatter(), fractionalSeconds: ISO8601DateFormatter.fractionalSecondsFormatter()))

	/// Parses an internet date-time with or without fractional seconds.
	static func date(fromISO8601 string: String) -> Date? {
		return iso8601Formatters.withLock { formatters in
			let formatter = string.contains(".") ? formatters.fractionalSeconds : formatters.plain
			return formatter.date(from: string)
		}
	}
}
