//
//  PropfindResponseParserTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

enum PropfindResponseParserTestsError: Error {
	case missingTestResource
}

func getXMLParser(forResource name: String, withExtension ext: String) throws -> XMLParser {
	guard let fileURL = Bundle.module.url(forResource: name, withExtension: ext), let xmlParser = XMLParser(contentsOf: fileURL) else {
		throw PropfindResponseParserTestsError.missingTestResource
	}
	return xmlParser
}

func getXMLParser(forHrefs hrefs: [String]) -> XMLParser {
	return XMLParser(data: getMultistatusData(forHrefs: hrefs))
}

/// An href that ends with a slash is a collection.
func getMultistatusData(forHrefs hrefs: [String]) -> Data {
	let responses = hrefs.map { href in
		let resourceType = href.hasSuffix("/") ? "<d:collection />" : ""
		return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(resourceType)</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
	}
	return getMultistatusData(forContent: responses.joined())
}

func getXMLParser(forMultistatusContent content: String) -> XMLParser {
	return XMLParser(data: getMultistatusData(forContent: content))
}

func getMultistatusData(forContent content: String) -> Data {
	return Data("<d:multistatus xmlns:d=\"DAV:\">\(content)</d:multistatus>".utf8)
}

/// Text of `byteCount` bytes of UTF-8 that starts with `prefix`, with its XML spelling. It is made mostly of 2-byte scalars, so that it holds fewer characters than bytes. Its `&` makes `XMLParser` report it in several parts.
func multibyteText(prefix: String, byteCount: Int) -> (text: String, xml: String) {
	let remaining = byteCount - prefix.utf8.count - 1
	let scalars = remaining / 2
	let head = prefix + String(repeating: "ä", count: scalars / 2)
	let tail = String(repeating: "ä", count: scalars - scalars / 2) + String(repeating: "b", count: remaining % 2)
	return (head + "&" + tail, head + "&amp;" + tail)
}

extension UnitTests {
	struct PropfindResponseParserTests {
		private static let responseFollowedByMalformedXML = "<d:response><d:href>/file.txt</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:propstat>"
		private static let okPropstat = "<d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>"

		@Test
		func responseWithSeveral200Propstats() throws {
			let xmlParser = try getXMLParser(forResource: "several-200-propstats", withExtension: "xml")
			let rootURL = try #require(URL(string: "/"))
			let parser = PropfindResponseParser(xmlParser, responseURL: rootURL)
			let expectedElements = try [
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/folder/", relativeTo: rootURL)), collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
			]
			#expect(try parser.getElements() == expectedElements)
		}

		/// The depth counts the segments of the percent-encoded path, so neither an encoded slash nor an escape that isn't valid UTF-8 changes it.
		@Test
		func depthCountsEncodedSegments() throws {
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/file.txt", "/folder/B%FCro.txt", "/folder/a%2Fb", "/folder/sub/deep.txt"])
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/file.txt")))
			#expect(try [-1, 0, 0, 0, 1] == parser.getElements().map(\.depth))
		}

		@Test
		func hrefInsidePropstatIsIgnored() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/a.txt</d:href><d:propstat><d:href>/other/b.txt</d:href><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == ["/folder/a.txt"])
		}

		/// The end of a `propstat` nested in another ends the group, so the `href` after it replaces the response's.
		@Test
		func hrefAfterNestedPropstatEndReplacesHref() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/a.txt</d:href><d:propstat><d:propstat/><d:href>/folder/b.txt</d:href></d:propstat><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == ["/folder/b.txt"])
		}

		/// The trailing `propstat` has no status of its own, so the element has no group with status 200.
		@Test
		func statusOutsidePropstatIsIgnored() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/a.txt</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat><d:status>HTTP/1.1 200 OK</d:status><d:propstat><d:prop><d:getcontentlength>5</d:getcontentlength></d:prop></d:propstat></d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().isEmpty)
		}

		@Test
		func collectionOutsideResourceTypeResetsCollection() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/a/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype><d:collection/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.collection) == [false])
		}

		/// `XMLParser` reports the text of an element that holds an entity or a character reference in several parts.
		@Test
		func textInSeveralPartsIsJoined() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/Tom&amp;Jerry.txt</d:href><d:propstat><d:prop><d:resourcetype/><d:getcontentlength>1&#48;24</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			let elements = try parser.getElements()
			#expect(elements.map(\.url.path) == ["/folder/Tom&Jerry.txt"])
			#expect(elements.map(\.contentLength) == [1024])
		}

		/// An element outside the `DAV:` namespace changes nothing, even with the local name of an element that the parser reads.
		@Test
		func foreignElementsWithDAVNamesChangeNothing() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response xmlns:x=\"urn:example\"><d:href>/folder/a<x:href/>.txt</d:href><x:href>/folder/b.txt</x:href><d:propstat><d:prop><d:resourcetype><x:collection/></d:resourcetype><d:getcontentlength>12</d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status><x:status>HTTP/1.1 404 Not Found</x:status></d:propstat></d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			let elements = try parser.getElements()
			#expect(elements.map(\.url.path) == ["/folder/a.txt"])
			#expect(elements.map(\.collection) == [false])
			#expect(elements.map(\.contentLength) == [12])
		}

		/// The requested element is listed after another element of its depth and spells its path with an escape.
		@Test
		func getRequestedElementPrefersElementWithPathOfResponseURL() throws {
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/other.txt", "/folder/file%2Etxt"])
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/file.txt")))
			#expect(try parser.getRequestedElement()?.url.path == "/folder/file.txt")
		}

		/// A proxy that removes a prefix from the path leaves a child of the requested folder at the depth of the response URL.
		@Test
		func getRequestedElementFallsBackToFirstElement() throws {
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/file.txt"])
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/proxy/folder/")))
			#expect(try parser.getRequestedElement()?.url.path == "/folder")
		}

		@Test
		func getRequestedElementWithUndecodableResponseURLTakesFirstElement() throws {
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/%E4.txt"])
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/%E4.txt")))
			#expect(try parser.getRequestedElement()?.url.path == "/folder")
		}

		@Test
		func getRequestedElementWithoutElements() throws {
			let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			#expect(try parser.getRequestedElement() == nil)
		}

		/// Malformed XML fails the call even after the element that it would return is complete.
		@Test
		func getRequestedElementThrowsOnMalformedXML() throws {
			let xmlParser = getXMLParser(forMultistatusContent: Self.responseFollowedByMalformedXML)
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/file.txt")))
			let error = try #require(throws: (any Error).self) { try parser.getRequestedElement() }
			#expect((error as NSError).domain == XMLParser.errorDomain)
		}

		@Test
		func parseHandsOverElementBeforeMalformedXML() throws {
			let parser = try PropfindResponseParser(getXMLParser(forMultistatusContent: Self.responseFollowedByMalformedXML), responseURL: #require(URL(string: "/file.txt")))
			var handedOverPaths = [String]()
			let error = try #require(throws: (any Error).self) { try parser.parse { handedOverPaths.append($0.url.path) } }
			#expect((error as NSError).domain == XMLParser.errorDomain)
			#expect(handedOverPaths == ["/file.txt"])
		}

		// MARK: - Caps

		/// The cap counts bytes of UTF-8, not characters, across the parts in which `XMLParser` reports the text.
		@Test
		func hrefAtTextCapParses() throws {
			let href = multibyteText(prefix: "/folder/", byteCount: WebDAVXMLLimits.maxTextLength)
			#expect(href.text.count < WebDAVXMLLimits.maxTextLength)
			let parser = try PropfindResponseParser(getXMLParser(forMultistatusContent: "<d:response><d:href>\(href.xml)</d:href>\(Self.okPropstat)</d:response>"), responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == [href.text])
			let longerParser = try PropfindResponseParser(getXMLParser(forMultistatusContent: "<d:response><d:href>\(href.xml)b</d:href>\(Self.okPropstat)</d:response>"), responseURL: #require(URL(string: "/folder/")))
			#expect(throws: WebDAVProviderError.responseTooLarge) { try longerParser.getElements() }
		}

		/// An `href` nested in another starts the count anew, so the enclosing one may hold more text in total. The text after the nested one ends still counts, because the enclosing one reads it.
		@Test
		func nestedHrefStartsTextCountAnew() throws {
			let padding = String(repeating: "a", count: 40 * 1024)
			let suffix = String(repeating: "c", count: WebDAVXMLLimits.maxTextLength - 1)
			let parser = try PropfindResponseParser(getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/\(padding)<d:href>x</d:href>\(suffix)</d:href>\(Self.okPropstat)</d:response>"), responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == ["/folder/x\(suffix)"])
			let longerParser = try PropfindResponseParser(getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/\(padding)<d:href>x</d:href>\(suffix)c</d:href>\(Self.okPropstat)</d:response>"), responseURL: #require(URL(string: "/folder/")))
			#expect(throws: WebDAVProviderError.responseTooLarge) { try longerParser.getElements() }
		}

		@Test
		func oversizedTextThrowsResponseTooLarge() throws {
			let oversized = String(repeating: "1", count: WebDAVXMLLimits.maxTextLength)
			let props = [
				"<d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 \(oversized)</d:status>",
				"<d:prop><d:getlastmodified>Thu, \(oversized)</d:getlastmodified></d:prop><d:status>HTTP/1.1 200 OK</d:status>",
				"<d:prop><d:getcontentlength>1<x:part>\(oversized)</x:part></d:getcontentlength></d:prop><d:status>HTTP/1.1 200 OK</d:status>"
			]
			for prop in props {
				let parser = try PropfindResponseParser(getXMLParser(forMultistatusContent: "<d:response xmlns:x=\"urn:example\"><d:href>/folder/a.txt</d:href><d:propstat>\(prop)</d:propstat></d:response>"), responseURL: #require(URL(string: "/folder/")))
				#expect(throws: WebDAVProviderError.responseTooLarge, "\(prop.prefix(60))") { try parser.getElements() }
			}
		}

		/// `multistatus`, the root, is level 1, so `multistatus`, `response`, `propstat` and `prop` take 4 of the levels.
		@Test
		func nestingBeyondDepthCapThrowsResponseTooLarge() throws {
			func parser(depth: Int) throws -> PropfindResponseParser {
				let nesting = depth - 4
				let foreign = String(repeating: "<x:n>", count: nesting) + String(repeating: "</x:n>", count: nesting)
				return try PropfindResponseParser(getXMLParser(forMultistatusContent: "<d:response xmlns:x=\"urn:example\"><d:href>/folder/a.txt</d:href><d:propstat><d:prop><d:resourcetype/>\(foreign)</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"), responseURL: #require(URL(string: "/folder/")))
			}
			#expect(try parser(depth: WebDAVXMLLimits.maxDepth).getElements().map(\.url.path) == ["/folder/a.txt"])
			#expect(throws: WebDAVProviderError.responseTooLarge) { try parser(depth: WebDAVXMLLimits.maxDepth + 1).getElements() }
		}

		@Test
		func textOutsideReadElementsIsNotHeld() throws {
			let whitespace = String(repeating: " ", count: 2 * 1024 * 1024)
			let value = String(repeating: "a", count: 2 * 1024 * 1024)
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response xmlns:x=\"urn:example\">\(whitespace)<d:href>/folder/a.txt</d:href><d:propstat><d:prop><d:resourcetype/><x:big>\(value)</x:big></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == ["/folder/a.txt"])
		}

		/// A `propstat` inside an `href` receives its own text, which doesn't count toward the `href`.
		@Test
		func propstatTextInsideHrefDoesNotCountTowardHref() throws {
			let value = String(repeating: "a", count: 70 * 1024)
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response xmlns:x=\"urn:example\"><d:href>/folder/a<d:propstat><d:prop><x:big>\(value)</x:big></d:prop></d:propstat>.txt</d:href>\(Self.okPropstat)</d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == ["/folder/a.txt"])
		}

		/// The end of a `propstat` nested in another ends the group early, and an `href` that started inside the outer group ends after that. It reads the text of the response's previous `href`, because the response takes in text only while one of its own `href`s is open.
		@Test
		func hrefEndingAfterNestedPropstatEndReadsPreviousHref() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/a</d:href><d:propstat><d:href><d:propstat/>b</d:href></d:propstat>\(Self.okPropstat)</d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == ["/folder/a"])
		}

		/// An `href` end that no `href` start in response state matched doesn't keep the response's next `href` from reading its text.
		@Test
		func hrefAfterUnmatchedHrefEndIsRead() throws {
			let xmlParser = getXMLParser(forMultistatusContent: "<d:response><d:href>/folder/a</d:href><d:propstat><d:href><d:propstat/>b</d:href></d:propstat><d:href>/folder/c</d:href>\(Self.okPropstat)</d:response>")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")))
			#expect(try parser.getElements().map(\.url.path) == ["/folder/c"])
		}
	}
}
