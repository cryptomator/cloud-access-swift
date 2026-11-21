//
//  MultistatusResponseParser.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// A member that a DELETE or MOVE of a collection couldn't delete or move, which the server reported in a 207 Multi-Status answer (RFC 4918, sections 9.6.1 and 9.9.4).
struct WebDAVMemberFailure: Error, Equatable {
	/// The status of the first failed member.
	let statusCode: Int
}

/// The status code of a `DAV:status` element's text, an HTTP status line such as `HTTP/1.1 423 Locked`.
func httpStatusCode(ofStatusLine statusLine: String) -> Int? {
	let statusSubsequences = statusLine.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
	return statusSubsequences.count > 1 ? Int(statusSubsequences[1]) : nil
}

/// Reads the member statuses of a 207 Multi-Status answer to a DELETE or MOVE.
enum MultistatusResponseParser {
	/**
	 Returns the status codes of the body's `DAV:status` elements.

	 - Throws: `WebDAVError.unexpectedResponse` if the body isn't well-formed XML, holds no status, or holds a status without a status code. Also if a status holds more than 64 KiB of UTF-8 text since the latest status start, or if the body nests deeper than 64 levels in any namespace (`WebDAVXMLLimits`).
	 */
	static func statusCodes(in data: Data) throws -> [Int] {
		let parser = XMLParser(data: data)
		parser.shouldProcessNamespaces = true
		let delegate = MultistatusResponseParserDelegate()
		parser.delegate = delegate
		guard parser.parse(), !delegate.statusCodes.isEmpty else {
			throw WebDAVError.unexpectedResponse
		}
		return delegate.statusCodes
	}
}

private class MultistatusResponseParserDelegate: NSObject, XMLParserDelegate {
	private(set) var statusCodes = [Int]()
	private var text = WebDAVXMLText()
	private var nestingLevel = 0

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		nestingLevel += 1
		guard nestingLevel <= WebDAVXMLLimits.maxDepth else {
			parser.abortParsing()
			return
		}
		guard let namespaceURI, namespaceURI == "DAV:", elementName == "status" else {
			return
		}
		text.start()
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		if !text.append(string) {
			parser.abortParsing()
		}
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		nestingLevel -= 1
		guard let namespaceURI, namespaceURI == "DAV:", elementName == "status" else {
			return
		}
		guard let statusCode = httpStatusCode(ofStatusLine: text.end()) else {
			parser.abortParsing()
			return
		}
		statusCodes.append(statusCode)
	}
}
