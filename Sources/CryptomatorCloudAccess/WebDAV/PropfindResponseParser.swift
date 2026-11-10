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

private extension URL {
	/// The non-empty segments of the percent-encoded path. The decoded path can't be split instead: it holds a `/` for every `%2F`, and it is empty for a URL with an escape that isn't valid UTF-8.
	var encodedPathSegments: [String] {
		return path(percentEncoded: true).pathSegments().filter { !$0.isEmpty }
	}

	/// The decoded segments of the path, or `nil` if a segment can't be decoded.
	var decodedPathSegments: [String]? {
		let segments = encodedPathSegments.map(\.removingPercentEncoding)
		return segments.contains(nil) ? nil : segments.compactMap(\.self)
	}
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

	private func getDepth(_ url: URL?) -> Int? {
		guard let elementURL = url else {
			return nil
		}
		return elementURL.encodedPathSegments.count - responseURL.encodedPathSegments.count
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

	/// The element to take from the response to a `Depth: 0` request: the first whose decoded path segments equal the response URL's, because a response can list other elements before the requested one. If none does, or if the response URL can't be decoded, the first element is taken, because a server behind a path-rewriting proxy spells its hrefs differently from the request. An element's depth can't pick the element there, because with a prefix removed, another element can have the response URL's depth.
	func getRequestedElement() throws -> PropfindResponseElement? {
		let elements = try getElements()
		guard let responseSegments = responseURL.decodedPathSegments else {
			return elements.first
		}
		return elements.first(where: { $0.url.decodedPathSegments == responseSegments }) ?? elements.first
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
	/// The decoded path segments of the first usable element at the folder's depth, taken as the folder's own. The server may spell them differently from the request, and `String` equality treats canonically equivalent segments (NFC and NFD) as equal. Until that element arrives, an element's parent segments aren't compared with them.
	private var folderSegments: [String]?
	private let responseSegments: [String]
	private var abortError: Error?

	init(_ parser: XMLParser, responseURL: URL, cache: DirectoryContentCache, snapshot: DirectoryContentSnapshot) {
		self.cache = cache
		self.snapshot = snapshot
		self.responseSegments = responseURL.decodedPathSegments ?? []
		super.init(parser, responseURL: responseURL)
	}

	/// A failed cache save aborts the parsing, so that a snapshot missing an element is never published.
	/// - Throws: The error of a failed cache save. `WebDAVProviderError.invalidResponse` if the response holds a second element at the folder's depth with another path, or no usable element of the folder itself. `CloudProviderError.itemTypeMismatch` if the folder's element is no collection. Otherwise the parser's error.
	func fillCache() throws {
		CloudAccessDDLogDebug("CachePropfindResponseParser: fillCache() for \(snapshot.folderEnumerationPath) called")
		do {
			_ = try getElements()
		} catch {
			throw abortError ?? error
		}
		guard folderSegments != nil else {
			throw WebDAVProviderError.invalidResponse
		}
		guard isDirectory else {
			throw CloudProviderError.itemTypeMismatch
		}
		CloudAccessDDLogDebug("CachePropfindResponseParser: fillCache() for \(snapshot.folderEnumerationPath) finished")
	}

	override func receivedElement(_ element: PropfindResponseElement) {
		guard let segments = element.url.decodedPathSegments else {
			CloudAccessDDLogDebug("CachePropfindResponseParser: skipping element \(element), because its path can't be decoded")
			return
		}
		// A segment with an encoded slash is no path component. In a parent segment, it would let the element be taken as the folder's own or as a child of the listed folder. A segment that decodes to the same as the response URL's at that position is the request's own, e.g., of a base URL with an encoded slash.
		let holdsEncodedSlash = segments.enumerated().contains { index, segment in
			segment.unicodeScalars.contains("/") && (index >= responseSegments.count || segment != responseSegments[index])
		}
		guard !holdsEncodedSlash else {
			CloudAccessDDLogDebug("CachePropfindResponseParser: skipping element \(element), because a segment of its path holds an encoded slash")
			return
		}
		if element.depth == 0 {
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
		guard let name = segments.last, name.isSinglePathComponent else {
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
}

private protocol PropfindParserDelegate: AnyObject {
	func receivedElement(_ element: PropfindResponseElement)
}
