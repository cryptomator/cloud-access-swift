//
//  Date+RFC822.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 07.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

private extension DateFormatter {
	static func rfc822Formatter() -> DateFormatter {
		let formatter = DateFormatter()
		formatter.locale = Locale(identifier: "en_US")
		formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
		return formatter
	}
}

extension Date {
	static func date(fromRFC822 string: String) -> Date? {
		return DateFormatter.rfc822Formatter().date(from: string)
	}

	static func rfc822String(from date: Date) -> String {
		return DateFormatter.rfc822Formatter().string(from: date)
	}
}
