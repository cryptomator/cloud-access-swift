//
//  WebDAVXMLLimits.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Caps on the WebDAV XML bodies. Real responses stay below them. Nextcloud nests 6 levels deep, and the percent-encoded `href` of a 4000-character path holds at most 48,000 bytes. The delegates enforce the text cap, on the text of an element they read, and the depth cap, which also bounds libxml2's stack of open elements. `WebDAVXMLGuard` enforces the others, which bound what libxml2 buffers before it calls a delegate or keeps for the whole parse. The delegates count UTF-8 bytes of the decoded text, and the guard counts bytes of the body.
enum WebDAVXMLLimits {
	static let maxTextLength = 64 * 1024
	static let maxDepth = 64
	/// A start or end tag, from `<` through `>`.
	static let maxTagLength = 16 * 1024
	static let maxAttributeCount = 64
	/// The content between the delimiters of a comment, CDATA section or processing instruction, the XML declaration included.
	static let maxDelimitedLength = 64 * 1024
	/// An entity or character reference in element content, between `&` and `;`.
	static let maxReferenceLength = 1024
	/// The distinct element and attribute qualified names, `xmlns` values and processing instruction targets of a body, by count and by their bytes in total.
	static let maxDistinctNames = 4096
	static let maxDistinctNameLength = 256 * 1024
}

/// The text of the elements that a delegate reads. It takes in text only while such an element is open, and keeps the text since the latest start of one until the next start.
struct WebDAVXMLText {
	private var text = ""
	private var openElements = 0

	mutating func start() {
		text = ""
		openElements += 1
	}

	/// Returns `false` instead of appending if the text would exceed `WebDAVXMLLimits.maxTextLength` bytes of UTF-8.
	mutating func append(_ string: String) -> Bool {
		guard openElements > 0 else {
			return true
		}
		guard text.utf8.count + string.utf8.count <= WebDAVXMLLimits.maxTextLength else {
			return false
		}
		text += string
		return true
	}

	/// The text since the latest start, which stays for an enclosing element that is still open.
	mutating func end() -> String {
		openElements = max(openElements - 1, 0)
		return text
	}
}
