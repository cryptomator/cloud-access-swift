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

/// An href that ends with a slash is a collection.
func getXMLParser(forHrefs hrefs: [String]) -> XMLParser {
	let responses = hrefs.map { href in
		let resourceType = href.hasSuffix("/") ? "<d:collection />" : ""
		return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(resourceType)</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
	}
	return getXMLParser(forMultistatusContent: responses.joined())
}

func getXMLParser(forMultistatusContent content: String) -> XMLParser {
	return XMLParser(data: Data("<d:multistatus xmlns:d=\"DAV:\">\(content)</d:multistatus>".utf8))
}

extension UnitTests {
	struct PropfindResponseParserTests {
		private static let responseFollowedByMalformedXML = "<d:response><d:href>/file.txt</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:propstat>"

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
	}
}
