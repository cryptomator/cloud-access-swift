//
//  WebDAVXMLLimits.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Caps on what the WebDAV XML delegates hold in memory: the text of an element they read and the nesting of a body. Real responses stay below them. Nextcloud nests 6 levels deep, and the percent-encoded `href` of a 4000-character path holds at most 48,000 bytes. libxml2 itself buffers each CDATA section, attribute value and comment whole before handing it on, up to its own limits of about 10 MB, so no delegate can bound them.
enum WebDAVXMLLimits {
	static let maxTextLength = 64 * 1024
	static let maxDepth = 64
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
