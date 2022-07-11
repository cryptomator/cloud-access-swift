//
//  PropfindResponseParser.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 07.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Promises

public enum PropfindResponseParserError: Error {
	case parsingAborted
}

struct PropfindResponseElement: Equatable {
	let depth: Int
	let url: URL
	let collection: Bool
	let lastModified: Date?
	let contentLength: Int?
}

private struct PropfindResponseElementProperties: Equatable {
	let collection: Bool
	let lastModified: Date?
	let contentLength: Int?
}

private class PropfindResponseElementPropertiesParserDelegate: NSObject, XMLParserDelegate {
	private weak var parentDelegate: PropfindResponseElementParserDelegate?

	private var xmlCharacterBuffer = ""
	private var insideOfResourceType = false
	private var collection = false
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
		autoreleasepool {
			switch elementName {
			case "propstat":
				if let statusCode = statusCode, statusCode == "200" {
					parentDelegate?.setElementProperties(PropfindResponseElementProperties(collection: collection, lastModified: lastModified, contentLength: contentLength))
				}
				parser.delegate = parentDelegate
			case "getlastmodified":
				lastModified = Date.date(fromRFC822: xmlCharacterBuffer)
			case "getcontentlength":
				contentLength = Int(xmlCharacterBuffer)
			case "resourcetype":
				insideOfResourceType = false
			case "status":
				statusCode = getStatusCode(xmlCharacterBuffer)
			default:
				break
			}
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
	private weak var parentDelegate: PropfindResponseParserDelegate?
	private let responseURL: URL

	// swiftlint:disable:next weak_delegate
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
		autoreleasepool {
			switch elementName {
			case "response":
				if let depth = depth, let url = url, let elementProperties = elementProperties {
					let element = PropfindResponseElement(depth: depth, url: url, collection: elementProperties.collection, lastModified: elementProperties.lastModified, contentLength: elementProperties.contentLength)
					parentDelegate?.receivedElement(element)
				}
				parser.delegate = parentDelegate
			case "href":
				url = getURL(xmlCharacterBuffer)
				depth = getDepth(url)
			default:
				break
			}
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

private class PropfindResponseParserDelegate: NSObject, XMLParserDelegate, PropfindParserDelegate {
	private let responseURL: URL

	// swiftlint:disable:next weak_delegate
	private var elementDelegate: PropfindResponseElementParserDelegate?
	weak var delegate: PropfindParserDelegate?

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

	fileprivate func receivedElement(_ element: PropfindResponseElement) {
		delegate?.receivedElement(element)
	}
}

class PropfindResponseParser: PropfindParserDelegate {
	private let parser: XMLParser
	private let responseURL: URL
	private lazy var elements = [PropfindResponseElement]()

	init(_ parser: XMLParser, responseURL: URL) {
		self.parser = parser
		self.parser.shouldProcessNamespaces = true
		self.responseURL = responseURL
	}

	func getElements() throws -> [PropfindResponseElement] {
		let delegate = PropfindResponseParserDelegate(responseURL: responseURL)
		delegate.delegate = self
		parser.delegate = delegate
		if parser.parse() {
			return elements
		} else {
			throw parser.parserError ?? PropfindResponseParserError.parsingAborted
		}
	}

	fileprivate func receivedElement(_ element: PropfindResponseElement) {
		elements.append(element)
	}
}

class CachePropfindResponseParser: PropfindResponseParser {
	let cache: DirectoryContentCache
	let folderEnumerationPath: CloudPath
	private var elementsCached: Int64 = 0
	private var isDirectory = false

	init(_ parser: XMLParser, responseURL: URL, cache: DirectoryContentCache, folderEnumerationPath: CloudPath) {
		self.cache = cache
		self.folderEnumerationPath = folderEnumerationPath
		super.init(parser, responseURL: responseURL)
	}

	func fillCache() throws {
		print("DEBUG: start fillCache for \(folderEnumerationPath) - \(Date())")
		_ = try getElements()
		guard isDirectory else {
			throw CloudProviderError.itemTypeMismatch
		}
		print("DEBUG: finished fillCache for \(folderEnumerationPath) - \(Date())")
	}

	override func receivedElement(_ element: PropfindResponseElement) {
		if !isDirectory, element.depth == 0 {
			isDirectory = element.collection
			return
		}
		elementsCached += 1
		let cloudPath = folderEnumerationPath.appendingPathComponent(element.url.lastPathComponent)
		let cloudItemMetadata = CloudItemMetadata(element, cloudPath: cloudPath)
		do {
			try cache.save(cloudItemMetadata, for: folderEnumerationPath, index: elementsCached)
		} catch {
			print("CachePropfindResponseParser caching element \(element) failed with error: \(error)")
		}
	}
}

private protocol PropfindParserDelegate: AnyObject {
	func receivedElement(_ element: PropfindResponseElement)
}
