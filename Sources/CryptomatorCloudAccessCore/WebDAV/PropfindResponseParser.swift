//
//  PropfindResponseParser.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 07.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

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

	/// Combines the properties of two `propstat` groups of one element, because a server may spread an element's properties over several groups with status 200. The element is a collection if either group says so. For the other properties, a value in `other` wins.
	func merging(_ other: PropfindResponseElementProperties) -> PropfindResponseElementProperties {
		return PropfindResponseElementProperties(collection: collection || other.collection, lastModified: other.lastModified ?? lastModified, contentLength: other.contentLength ?? contentLength)
	}
}

/// Outside a `response`, the delegate reads only the start of the next one. Inside a `response`, it reads the `href` and the start of a `propstat`. Inside a `propstat`, it reads only that group's properties and status. A `response` or `propstat` ends at the next end tag of that name, even a nested element's.
///
/// It takes in text only inside the elements whose text it reads: a response's `href` and a propstat's `getlastmodified`, `getcontentlength` and `status`. More than 64 KiB of UTF-8 text since the latest start of such an element, or nesting deeper than 64 levels in any namespace, aborts the parsing with `WebDAVProviderError.responseTooLarge` (`WebDAVXMLLimits`).
private final class PropfindResponseParserDelegate: NSObject, XMLParserDelegate {
	private struct PropstatState {
		var text = WebDAVXMLText()
		var insideOfResourceType = false
		var collection = false
		var lastModified: Date?
		var contentLength: Int?
		var statusCode: Int?

		mutating func didStartElement(_ elementName: String) {
			switch elementName {
			case "getlastmodified", "getcontentlength", "status":
				text.start()
			case "resourcetype":
				insideOfResourceType = true
			case "collection":
				collection = insideOfResourceType
			default:
				break
			}
		}

		mutating func didEndElement(_ elementName: String) {
			switch elementName {
			case "getlastmodified":
				lastModified = Date.date(fromRFC822: text.end())
			case "getcontentlength":
				contentLength = Int(text.end())
			case "resourcetype":
				insideOfResourceType = false
			case "status":
				statusCode = httpStatusCode(ofStatusLine: text.end())
			default:
				break
			}
		}
	}

	private struct ResponseState {
		var text = WebDAVXMLText()
		var depth: Int?
		var url: URL?
		var elementProperties: PropfindResponseElementProperties?
		var propstat: PropstatState?

		mutating func addElementProperties(_ properties: PropfindResponseElementProperties) {
			elementProperties = elementProperties?.merging(properties) ?? properties
		}
	}

	private let responseURL: URL
	private let handleElement: (PropfindResponseElement) throws -> Void
	private var response: ResponseState?
	private var nestingLevel = 0
	private(set) var abortError: Error?

	init(responseURL: URL, handleElement: @escaping (PropfindResponseElement) throws -> Void) {
		self.responseURL = responseURL
		self.handleElement = handleElement
	}

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		nestingLevel += 1
		guard nestingLevel <= WebDAVXMLLimits.maxDepth else {
			CloudAccessDDLogDebug("PropfindResponseParser: aborting, because the nesting exceeds \(WebDAVXMLLimits.maxDepth) levels")
			abort(parser, with: WebDAVProviderError.responseTooLarge)
			return
		}
		guard let namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		if response == nil {
			if elementName == "response" {
				response = ResponseState()
			}
		} else if response?.propstat != nil {
			response?.propstat?.didStartElement(elementName)
		} else {
			switch elementName {
			case "propstat":
				response?.propstat = PropstatState()
			case "href":
				response?.text.start()
			default:
				break
			}
		}
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		let appended = if response?.propstat != nil {
			response?.propstat?.text.append(string)
		} else {
			response?.text.append(string)
		}
		if appended == false {
			CloudAccessDDLogDebug("PropfindResponseParser: aborting, because an element's text exceeds \(WebDAVXMLLimits.maxTextLength) bytes")
			abort(parser, with: WebDAVProviderError.responseTooLarge)
		}
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		nestingLevel -= 1
		guard let namespaceURI, namespaceURI == "DAV:" else {
			return
		}
		autoreleasepool {
			if response?.propstat != nil {
				didEndElementInPropstat(elementName)
			} else if response != nil {
				didEndElementInResponse(elementName, parser: parser)
			}
		}
	}

	// MARK: - Internal

	private func didEndElementInPropstat(_ elementName: String) {
		guard elementName == "propstat" else {
			response?.propstat?.didEndElement(elementName)
			return
		}
		if let propstat = response?.propstat, propstat.statusCode == 200 {
			response?.addElementProperties(PropfindResponseElementProperties(collection: propstat.collection, lastModified: propstat.lastModified, contentLength: propstat.contentLength))
		}
		response?.propstat = nil
	}

	private func didEndElementInResponse(_ elementName: String, parser: XMLParser) {
		switch elementName {
		case "response":
			if let depth = response?.depth, let url = response?.url, let elementProperties = response?.elementProperties {
				let element = PropfindResponseElement(depth: depth, url: url, collection: elementProperties.collection, lastModified: elementProperties.lastModified, contentLength: elementProperties.contentLength)
				do {
					try handleElement(element)
				} catch {
					abort(parser, with: error)
				}
			}
			response = nil
		case "href":
			let url = getURL(response?.text.end() ?? "")
			response?.url = url
			response?.depth = getDepth(url)
		default:
			break
		}
	}

	private func abort(_ parser: XMLParser, with error: Error) {
		abortError = error
		parser.abortParsing()
	}

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

final class PropfindResponseParser {
	private let parser: XMLParser
	private let responseURL: URL

	init(_ parser: XMLParser, responseURL: URL) {
		self.parser = parser
		self.parser.shouldProcessNamespaces = true
		self.responseURL = responseURL
	}

	/// Passes each element to `handleElement` as its `response` ends, so that a listing is read without holding its elements.
	/// - Throws: The error that `handleElement` threw, which aborts the parsing. `WebDAVProviderError.responseTooLarge` if an element's text or the nesting exceeds `WebDAVXMLLimits`. Otherwise the parser's error.
	func parse(_ handleElement: @escaping (PropfindResponseElement) throws -> Void) throws {
		let delegate = PropfindResponseParserDelegate(responseURL: responseURL, handleElement: handleElement)
		parser.delegate = delegate
		guard parser.parse() else {
			throw delegate.abortError ?? parser.parserError ?? PropfindResponseParserError.parsingAborted
		}
	}

	func getElements() throws -> [PropfindResponseElement] {
		var elements = [PropfindResponseElement]()
		try parse { elements.append($0) }
		return elements
	}

	/// The element to take from the response to a `Depth: 0` request: the first whose decoded path segments equal the response URL's, because a response can list other elements before the requested one. If none does, or if the response URL can't be decoded, the first element is taken, because a server behind a path-rewriting proxy spells its hrefs differently from the request. An element's depth can't pick the element there, because with a prefix removed, another element can have the response URL's depth.
	func getRequestedElement() throws -> PropfindResponseElement? {
		let elements = try getElements()
		guard let responseSegments = responseURL.decodedPathSegments else {
			return elements.first
		}
		return elements.first(where: { $0.url.decodedPathSegments == responseSegments }) ?? elements.first
	}
}

final class CachePropfindResponseParser {
	let cache: DirectoryContentCache
	let snapshot: DirectoryContentSnapshot
	private let parser: PropfindResponseParser
	private var elementsCached: Int64 = 0
	private var isDirectory = false
	/// The decoded path segments of the first usable element at the folder's depth, taken as the folder's own. The server may spell them differently from the request, and `String` equality treats canonically equivalent segments (NFC and NFD) as equal. Until that element arrives, an element's parent segments aren't compared with them.
	private var folderSegments: [String]?
	private let responseSegments: [String]

	init(_ parser: XMLParser, responseURL: URL, cache: DirectoryContentCache, snapshot: DirectoryContentSnapshot) {
		self.cache = cache
		self.snapshot = snapshot
		self.responseSegments = responseURL.decodedPathSegments ?? []
		self.parser = PropfindResponseParser(parser, responseURL: responseURL)
	}

	/// A failed cache save aborts the parsing, so that a snapshot missing an element is never published. Once the task is cancelled, the parsing stops at the next element.
	/// - Throws: The error of a failed cache save, or `CancellationError`. `WebDAVProviderError.invalidResponse` if the response holds a second element at the folder's depth with another path, or no usable element of the folder itself. `CloudProviderError.itemTypeMismatch` if the folder's element is no collection. `WebDAVProviderError.responseTooLarge` if an element's text or the nesting exceeds `WebDAVXMLLimits`. Otherwise the parser's error.
	func fillCache() throws {
		CloudAccessDDLogDebug("CachePropfindResponseParser: fillCache() for \(snapshot.folderEnumerationPath) called")
		try parser.parse { element in
			try Task.checkCancellation()
			try self.cacheElement(element)
		}
		guard folderSegments != nil else {
			throw WebDAVProviderError.invalidResponse
		}
		guard isDirectory else {
			throw CloudProviderError.itemTypeMismatch
		}
		CloudAccessDDLogDebug("CachePropfindResponseParser: fillCache() for \(snapshot.folderEnumerationPath) finished")
	}

	private func cacheElement(_ element: PropfindResponseElement) throws {
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
				throw WebDAVProviderError.invalidResponse
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
			throw error
		}
	}
}
