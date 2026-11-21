//
//  MultistatusResponseParserTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct MultistatusResponseParserTests {
		/// An element outside the `DAV:` namespace changes nothing, even with the local name `status`.
		@Test
		func foreignStatusElementsChangeNothing() throws {
			let data = getMultistatusData(forContent: "<d:response xmlns:x=\"urn:example\"><d:href>/folder/a.txt</d:href><d:status>HTTP/1.1 <x:status/>423 Locked</d:status><x:status>HTTP/1.1 200 OK</x:status></d:response>")
			#expect(try MultistatusResponseParser.statusCodes(in: data) == [423])
		}

		/// A status nested in another starts the text anew, so the enclosing one reads only the text from the nested one's start on.
		@Test
		func nestedStatusesReadNestedText() throws {
			let data = getMultistatusData(forContent: "<d:response><d:href>/folder/a.txt</d:href><d:status>HTTP/1.1 207 x<d:status>HTTP/1.1 423 Locked</d:status></d:status></d:response>")
			#expect(try MultistatusResponseParser.statusCodes(in: data) == [423, 423])
		}

		// MARK: - Caps

		/// The cap counts bytes of UTF-8, not characters, across the parts in which `XMLParser` reports the text.
		@Test
		func statusAtTextCapParses() throws {
			let status = multibyteText(prefix: "HTTP/1.1 423 ", byteCount: WebDAVXMLLimits.maxTextLength)
			#expect(status.text.count < WebDAVXMLLimits.maxTextLength)
			#expect(try MultistatusResponseParser.statusCodes(in: response(status: status.xml)) == [423])
			#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: response(status: status.xml + "b")) }
		}

		/// A status nested in another starts the count anew, so the enclosing one may hold more text in total. The text after the nested one ends still counts, because the enclosing one reads it.
		@Test
		func nestedStatusStartsTextCountAnew() throws {
			let padding = String(repeating: "a", count: 40 * 1024)
			let innerStatus = "HTTP/1.1 423 "
			let suffix = String(repeating: "c", count: WebDAVXMLLimits.maxTextLength - innerStatus.utf8.count - "Locked".utf8.count) + "Locked"
			let data = getMultistatusData(forContent: "<d:response><d:href>/folder/a.txt</d:href><d:status>\(padding)<d:status>\(innerStatus)</d:status>\(suffix)</d:status></d:response>")
			#expect(try MultistatusResponseParser.statusCodes(in: data) == [423, 423])
			let longerData = getMultistatusData(forContent: "<d:response><d:href>/folder/a.txt</d:href><d:status>\(padding)<d:status>\(innerStatus)</d:status>c\(suffix)</d:status></d:response>")
			#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: longerData) }
		}

		/// `multistatus`, the root, is level 1, so `multistatus` and `response` take 2 of the levels.
		@Test
		func nestingBeyondDepthCapThrowsUnexpectedResponse() throws {
			func data(depth: Int) -> Data {
				let nesting = depth - 2
				let foreign = foreignNesting(count: nesting)
				return getMultistatusData(forContent: "<d:response xmlns:x=\"urn:example\"><d:href>/folder/a.txt</d:href><d:status>HTTP/1.1 423 Locked</d:status>\(foreign)</d:response>")
			}
			#expect(try MultistatusResponseParser.statusCodes(in: data(depth: WebDAVXMLLimits.maxDepth)) == [423])
			#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: data(depth: WebDAVXMLLimits.maxDepth + 1)) }
		}

		@Test
		func textOutsideStatusIsNotHeld() throws {
			let whitespace = String(repeating: " ", count: 35 * 1024)
			let value = String(repeating: "a", count: 35 * 1024)
			let data = getMultistatusData(forContent: "<d:response xmlns:x=\"urn:example\">\(whitespace)<d:href>/folder/a.txt</d:href><d:propstat><d:prop><x:big>\(value)</x:big></d:prop><d:status>HTTP/1.1 423 Locked</d:status></d:propstat></d:response>")
			#expect(try MultistatusResponseParser.statusCodes(in: data) == [423])
		}

		/// A cap breach fails the body, even after a member that failed.
		@Test
		func oversizedStatusAfterFailedMemberThrowsUnexpectedResponse() throws {
			let oversized = String(repeating: "a", count: WebDAVXMLLimits.maxTextLength)
			let data = getMultistatusData(forContent: "<d:response><d:href>/folder/a.txt</d:href><d:status>HTTP/1.1 423 Locked</d:status></d:response><d:response><d:href>/folder/b.txt</d:href><d:status>HTTP/1.1 423 \(oversized)</d:status></d:response>")
			#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: data) }
		}

		/// The line names the cap that aborted the parsing, so that it tells the delegate's abort from the guard's refusal of the same error.
		@Test
		func abortLogsExceededCap() throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let nesting = foreignNesting(count: WebDAVXMLLimits.maxDepth)
			let cases = [
				(response(status: "HTTP/1.1 423 " + String(repeating: "a", count: WebDAVXMLLimits.maxTextLength)), "MultistatusResponseParser: aborting, because a status's text exceeds \(WebDAVXMLLimits.maxTextLength) bytes"),
				(getMultistatusData(forContent: "<d:response xmlns:x=\"urn:example\"><d:href>/folder/a.txt</d:href><d:status>HTTP/1.1 423 Locked</d:status>\(nesting)</d:response>"), "MultistatusResponseParser: aborting, because the nesting exceeds \(WebDAVXMLLimits.maxDepth) levels")
			]
			for (data, expectedLine) in cases {
				#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: data) }
				#expect(logCapture.messages.filter { $0.hasPrefix("MultistatusResponseParser: aborting") }.last == expectedLine, "\(logCapture.joinedMessages)")
			}
		}

		// MARK: - Markup Guard

		/// `XMLParser` parses this body, so `unexpectedResponse` shows that the guard refused it.
		@Test
		func tooManyAttributesThrowsUnexpectedResponse() throws {
			#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: responseWithTooManyAttributes(value: "v")) }
		}

		@Test
		func doctypeThrowsUnexpectedResponse() throws {
			let data = Data("<!DOCTYPE d:multistatus>".utf8) + response(status: "HTTP/1.1 423 Locked")
			#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: data) }
		}

		@Test
		func refusalLogsConstructWithoutContent() throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}

			#expect(throws: WebDAVError.unexpectedResponse) { try MultistatusResponseParser.statusCodes(in: responseWithTooManyAttributes(value: "SECRET-MARKER")) }
			expectAttributeRefusalLog(in: logCapture, prefix: "MultistatusResponseParser: refused response markup:", marker: "SECRET-MARKER")
		}

		// MARK: - Helpers

		private func responseWithTooManyAttributes(value: String) -> Data {
			return getMultistatusData(forContent: "<d:response \(attributesOverCap(value: value))><d:href>/folder/a.txt</d:href><d:status>HTTP/1.1 423 Locked</d:status></d:response>")
		}

		private func response(status: String) -> Data {
			return getMultistatusData(forContent: "<d:response><d:href>/folder/a.txt</d:href><d:status>\(status)</d:status></d:response>")
		}
	}
}
