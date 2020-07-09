//
//  PropfindResponseParser.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 07.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

enum PropfindResponseParserError: Error {
	case parsingAborted
}

internal struct PropfindResponseElement {
	let depth: Int
	let href: URL
	let collection: Bool
	let lastModified: Date?
	let contentLength: Int?
}

internal class PropfindResponseElementParserDelegate: NSObject, XMLParserDelegate {
	let rootDelegate: PropfindResponseParserDelegate
	let baseURL: URL

	var xmlCharacterBuffer = ""
	var insideOfResourceType = false
	var collection = false

	var depth: Int?
	var href: URL?
	var lastModified: Date?
	var contentLength: Int?

	init(rootDelegate: PropfindResponseParserDelegate, baseURL: URL) {
		self.rootDelegate = rootDelegate
		self.baseURL = baseURL
	}

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		guard let namespaceURI = namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		switch elementName {
		case "response", "href", "getlastmodified", "getcontentlength":
			xmlCharacterBuffer = ""
		case "resourcetype":
			insideOfResourceType = true
		case "collection":
			collection = insideOfResourceType
		default:
			break
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		xmlCharacterBuffer += string
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		guard let namespaceURI = namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		switch elementName {
		case "response":
			if let depth = depth, let href = href {
				rootDelegate.addElement(PropfindResponseElement(depth: depth, href: href, collection: collection, lastModified: lastModified, contentLength: contentLength))
			}
			parser.delegate = rootDelegate
		case "href":
			href = getURL(xmlCharacterBuffer)
			depth = getDepth(href)
		case "getlastmodified":
			lastModified = Date.date(fromRFC822: xmlCharacterBuffer)
		case "getcontentlength":
			contentLength = Int(xmlCharacterBuffer)
		case "resourcetype":
			insideOfResourceType = false
		default:
			break
		}
	}

	// MARK: - Internal

	private func getURL(_ href: String) -> URL? {
		// workaround, because some servers don't escape spaces (e.g. cubby.com, powered by "IT Hit WebDAV Server .Net v3.0.520.0")
		guard let escapedHref = href.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: " ").inverted) else {
			return nil
		}
		return URL(string: escapedHref, relativeTo: baseURL)
	}

	private func getDepth(_ href: URL?) -> Int? {
		guard let elementURL = href else {
			return nil
		}
		return elementURL.path.split(separator: "/").count - baseURL.path.split(separator: "/").count
	}
}

internal class PropfindResponseParserDelegate: NSObject, XMLParserDelegate {
	let baseURL: URL

	var elements: [PropfindResponseElement] = []
	var elementDelegate: PropfindResponseElementParserDelegate?

	init(baseURL: URL) {
		self.baseURL = baseURL
	}

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		guard let namespaceURI = namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		if elementName == "response" {
			elementDelegate = PropfindResponseElementParserDelegate(rootDelegate: self, baseURL: baseURL)
			parser.delegate = elementDelegate
		}
	}

	func addElement(_ element: PropfindResponseElement) {
		elements.append(element)
	}
}

internal class PropfindResponseParser {
	private let parser: XMLParser
	private let baseURL: URL

	init(_ parser: XMLParser, baseURL: URL) {
		self.parser = parser
		self.parser.shouldProcessNamespaces = true
		self.baseURL = baseURL
	}

	func getElements() throws -> [PropfindResponseElement] {
		let delegate = PropfindResponseParserDelegate(baseURL: baseURL)
		parser.delegate = delegate
		if parser.parse() {
			return delegate.elements
		} else {
			throw parser.parserError ?? PropfindResponseParserError.parsingAborted
		}
	}
}
