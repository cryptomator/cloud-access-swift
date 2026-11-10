//
//  PropfindResponseParser.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 07.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

enum PropfindResponseParserError: Error {
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
		guard let namespaceURI, namespaceURI == "DAV:" else {
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
		guard let namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		autoreleasepool {
			switch elementName {
			case "propstat":
				if let statusCode, statusCode == "200" {
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
		guard let status else {
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
		guard let namespaceURI, namespaceURI == "DAV:" else {
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
		guard let namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		autoreleasepool {
			switch elementName {
			case "response":
				if let depth, let url, let elementProperties {
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

	/// Splits by Unicode scalar and counts the non-empty segments, because a slash can form one `Character` with an adjacent mark.
	private func getDepth(_ url: URL?) -> Int? {
		guard let elementURL = url else {
			return nil
		}
		return elementURL.path.unicodeScalars.split(separator: "/").count - responseURL.path.unicodeScalars.split(separator: "/").count
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
		guard let namespaceURI, namespaceURI == "DAV:" else {
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
	fileprivate let parser: XMLParser
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
	let snapshot: DirectoryContentSnapshot
	private var elementsCached: Int64 = 0
	private var isDirectory = false
	/// The decoded path segments of the first element at the folder's depth, taken as the folder's own. The server may spell them differently from the request. Until that element arrives, an element's parent isn't checked.
	private var folderSegments: [String]?
	private let responseSegmentCount: Int?
	private var abortError: Error?

	init(_ parser: XMLParser, responseURL: URL, cache: DirectoryContentCache, snapshot: DirectoryContentSnapshot) {
		self.cache = cache
		self.snapshot = snapshot
		self.responseSegmentCount = CachePropfindResponseParser.decodedPathSegments(of: responseURL)?.count
		super.init(parser, responseURL: responseURL)
	}

	/// A failed cache save aborts the parsing, so that a snapshot missing an element is never published. A second element at the folder's depth with another path aborts it with `WebDAVProviderError.invalidResponse`. Either error is thrown instead of the parser's.
	func fillCache() throws {
		CloudAccessDDLogDebug("CachePropfindResponseParser: fillCache() for \(snapshot.folderEnumerationPath) called")
		do {
			_ = try getElements()
		} catch {
			throw abortError ?? error
		}
		guard isDirectory else {
			throw CloudProviderError.itemTypeMismatch
		}
		CloudAccessDDLogDebug("CachePropfindResponseParser: fillCache() for \(snapshot.folderEnumerationPath) finished")
	}

	override func receivedElement(_ element: PropfindResponseElement) {
		// The depth counts the segments of the decoded path, which is empty for a path that can't be decoded and longer for one with an encoded slash. Such an element isn't at the folder's depth, so its own segments must agree.
		if element.depth == 0, let segments = CachePropfindResponseParser.decodedPathSegments(of: element.url), segments.count == responseSegmentCount {
			if let folderSegments, segments != folderSegments {
				// Either may be the listed folder, which one pass can't tell. Elements cached since the first were checked against it, so they may belong to another folder.
				CloudAccessDDLogDebug("CachePropfindResponseParser: aborting, because element \(element) is a second element at the depth of the listed folder with another path")
				abortError = WebDAVProviderError.invalidResponse
				parser.abortParsing()
				return
			}
			folderSegments = segments
			isDirectory = isDirectory || element.collection
			return
		}
		guard element.depth == 1 else {
			CloudAccessDDLogDebug("CachePropfindResponseParser: skipping element \(element), because it isn't one level deeper than the folder")
			return
		}
		guard let segments = CachePropfindResponseParser.decodedPathSegments(of: element.url), let name = segments.last, name.isSinglePathComponent else {
			CloudAccessDDLogDebug("CachePropfindResponseParser: skipping element \(element), because its name is no single path component")
			return
		}
		if let folderSegments, !segments.dropLast().elementsEqual(folderSegments) {
			CloudAccessDDLogDebug("CachePropfindResponseParser: skipping element \(element), because it isn't in the folder")
			return
		}
		elementsCached += 1
		let cloudPath = snapshot.folderEnumerationPath.appendingPathComponent(name)
		let cloudItemMetadata = CloudItemMetadata(element, cloudPath: cloudPath)
		do {
			try cache.save(cloudItemMetadata, in: snapshot, index: elementsCached)
		} catch {
			CloudAccessDDLogDebug("CachePropfindResponseParser: caching element \(element) failed with error: \(error)")
			abortError = error
			parser.abortParsing()
		}
	}

	/// Splits the percent-encoded path before decoding its non-empty segments, because decoding first turns `%2F` into a `/` that the cloud path would read as a separator. `String` equality treats canonically equivalent segments (NFC and NFD) as equal.
	/// - Returns: `nil` if a segment can't be decoded.
	private static func decodedPathSegments(of url: URL) -> [String]? {
		let segments = url.path(percentEncoded: true).pathSegments().filter { !$0.isEmpty }.map(\.removingPercentEncoding)
		return segments.contains(nil) ? nil : segments.compactMap(\.self)
	}
}

private protocol PropfindParserDelegate: AnyObject {
	func receivedElement(_ element: PropfindResponseElement)
}
