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
	let href: String?
	let lastModified: Date?
	let contentLength: Int?
	let collection: Bool?
}

internal class PropfindResponseElementParserDelegate: NSObject, XMLParserDelegate {
	let rootDelegate: PropfindResponseParserDelegate

	var xmlCharacterBuffer = ""
	var insideOfResourceType = false

	var href: String?
	var lastModified: Date?
	var contentLength: Int?
	var collection: Bool?

	init(rootDelegate: PropfindResponseParserDelegate) {
		self.rootDelegate = rootDelegate
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
			rootDelegate.addElement(PropfindResponseElement(href: href, lastModified: lastModified, contentLength: contentLength, collection: collection))
			parser.delegate = rootDelegate
		case "href":
			href = xmlCharacterBuffer
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
}

internal class PropfindResponseParserDelegate: NSObject, XMLParserDelegate {
	var elements: [PropfindResponseElement] = []
	var elementDelegate: PropfindResponseElementParserDelegate?

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		guard let namespaceURI = namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		if elementName == "response" {
			elementDelegate = PropfindResponseElementParserDelegate(rootDelegate: self)
			parser.delegate = elementDelegate
		}
	}

	func addElement(_ element: PropfindResponseElement) {
		elements.append(element)
	}
}

internal class PropfindResponseParser {
	private let parser: XMLParser

	init(_ parser: XMLParser) {
		self.parser = parser
		self.parser.shouldProcessNamespaces = true
	}

	func getElements() throws -> [PropfindResponseElement] {
		let delegate = PropfindResponseParserDelegate()
		parser.delegate = delegate
		if parser.parse() {
			return delegate.elements
		} else {
			throw parser.parserError ?? PropfindResponseParserError.parsingAborted
		}
	}
}
