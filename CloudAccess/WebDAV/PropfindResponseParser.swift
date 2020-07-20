//
//  PropfindResponseParser.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 07.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public enum PropfindResponseParserError: Error {
	case parsingAborted
}

struct PropfindResponseElement: Equatable {
	let depth: Int
	let url: URL
	let collection: Bool?
	let lastModified: Date?
	let contentLength: Int?
}

private struct PropfindResponseElementProperties: Equatable {
	let collection: Bool?
	let lastModified: Date?
	let contentLength: Int?
}

private class PropfindResponseElementPropertiesParserDelegate: NSObject, XMLParserDelegate {
	private let parentDelegate: PropfindResponseElementParserDelegate

	private var xmlCharacterBuffer = ""
	private var insideOfResourceType = false
	private var collection: Bool?
	private var lastModified: Date?
	private var contentLength: Int?
	private var statusCode: String?

	init(parentDelegate: PropfindResponseElementParserDelegate) {
		self.parentDelegate = parentDelegate
	}

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		guard let namespaceURI = namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		switch elementName {
		case "getlastmodified", "getcontentlength", "status":
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
		case "propstat":
			if let statusCode = statusCode, statusCode == "200" {
				parentDelegate.setElementProperties(PropfindResponseElementProperties(collection: collection, lastModified: lastModified, contentLength: contentLength))
			}
			parser.delegate = parentDelegate
		case "getlastmodified":
			lastModified = Date.date(fromRFC822: xmlCharacterBuffer)
		case "getcontentlength":
			contentLength = Int(xmlCharacterBuffer)
		case "resourcetype":
			insideOfResourceType = false
			if collection == nil {
				collection = false
			}
		case "status":
			statusCode = getStatusCode(xmlCharacterBuffer)
		default:
			break
		}
	}

	// MARK: - Internal

	private func getStatusCode(_ status: String?) -> String? {
		guard let status = status else {
			return nil
		}
		let statusSubsequences = status.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
		return statusSubsequences.count > 1 ? String(statusSubsequences[1]) : nil
	}
}

private class PropfindResponseElementParserDelegate: NSObject, XMLParserDelegate {
	private let parentDelegate: PropfindResponseParserDelegate
	private let responseURL: URL

	private var elementPropertiesDelegate: PropfindResponseElementPropertiesParserDelegate?
	private var xmlCharacterBuffer = ""
	private var depth: Int?
	private var url: URL?

	var elementProperties: PropfindResponseElementProperties?

	init(parentDelegate: PropfindResponseParserDelegate, responseURL: URL) {
		self.parentDelegate = parentDelegate
		self.responseURL = responseURL
	}

	func setElementProperties(_ elementProperties: PropfindResponseElementProperties) {
		self.elementProperties = elementProperties
	}

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		guard let namespaceURI = namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		switch elementName {
		case "propstat":
			elementPropertiesDelegate = PropfindResponseElementPropertiesParserDelegate(parentDelegate: self)
			parser.delegate = elementPropertiesDelegate
		case "href":
			xmlCharacterBuffer = ""
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
			if let depth = depth, let url = url, let elementProperties = elementProperties {
				parentDelegate.elements.append(PropfindResponseElement(depth: depth, url: url, collection: elementProperties.collection, lastModified: elementProperties.lastModified, contentLength: elementProperties.contentLength))
			}
			parser.delegate = parentDelegate
		case "href":
			url = getURL(xmlCharacterBuffer)
			depth = getDepth(url)
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
		return URL(string: escapedHref, relativeTo: responseURL)
	}

	private func getDepth(_ url: URL?) -> Int? {
		guard let elementURL = url else {
			return nil
		}
		return elementURL.path.split(separator: "/").count - responseURL.path.split(separator: "/").count
	}
}

private class PropfindResponseParserDelegate: NSObject, XMLParserDelegate {
	private let responseURL: URL

	private var elementDelegate: PropfindResponseElementParserDelegate?

	var elements: [PropfindResponseElement] = []

	init(responseURL: URL) {
		self.responseURL = responseURL
	}

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		guard let namespaceURI = namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		if elementName == "response" {
			elementDelegate = PropfindResponseElementParserDelegate(parentDelegate: self, responseURL: responseURL)
			parser.delegate = elementDelegate
		}
	}
}

class PropfindResponseParser {
	private let parser: XMLParser
	private let responseURL: URL

	init(_ parser: XMLParser, responseURL: URL) {
		self.parser = parser
		self.parser.shouldProcessNamespaces = true
		self.responseURL = responseURL
	}

	func getElements() throws -> [PropfindResponseElement] {
		let delegate = PropfindResponseParserDelegate(responseURL: responseURL)
		parser.delegate = delegate
		if parser.parse() {
			return delegate.elements
		} else {
			throw parser.parserError ?? PropfindResponseParserError.parsingAborted
		}
	}
}
