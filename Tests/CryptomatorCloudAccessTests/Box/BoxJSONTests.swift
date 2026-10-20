//
//  BoxJSONTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class BoxJSONTests: XCTestCase {
	/// The date of an earlier download must stay equal, so the parser must match the Box SDK's formatters exactly, including the forms that they accept beyond their format.
	func testDateTimeIsParsedAsBySDKFormatters() throws {
		let referenceFormatters = ["yyyy-MM-dd'T'HH:mm:ssxxx", "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"].map { dateFormat in
			let formatter = DateFormatter()
			formatter.dateFormat = dateFormat
			formatter.timeZone = TimeZone(secondsFromGMT: 0)
			formatter.locale = Locale(identifier: "en_US_POSIX")
			formatter.calendar = Calendar(identifier: .iso8601)
			return formatter
		}
		for string in ["2026-10-20T11:05:00-07:00", "2026-10-20T11:05:00.123+00:00", "2026-10-20T11:05:00Z", "2026-10-20T11:05:00+0000"] {
			let expectedDate = try XCTUnwrap(referenceFormatters[0].date(from: string) ?? referenceFormatters[1].date(from: string), string)
			XCTAssertEqual(expectedDate, BoxJSON.date(fromBoxDateTime: string), string)
		}
		XCTAssertNil(BoxJSON.date(fromBoxDateTime: "2026-10-20 11:05:00"))
	}

	func testListingWithWebLinkDecodes() throws {
		let items = try BoxJSON.decode(BoxItems.self, from: Data(BoxMockResponse.items([#"{"type":"web_link","id":"9","name":"Link"}"#, BoxMockResponse.fileEntry(id: "5", name: "file.txt")], nextMarker: "M").utf8))

		XCTAssertEqual(["web_link", "file"], items.entries?.map(\.type))
		XCTAssertEqual("M", items.nextMarker)
	}

	func testEntryWithoutIdentifierThrows() {
		XCTAssertThrowsError(try BoxJSON.decode(BoxItems.self, from: Data(BoxMockResponse.items([#"{"type":"file","name":"file.txt"}"#]).utf8))) { error in
			XCTAssertEqual(.unexpectedContent, error as? BoxError)
		}
	}
}
