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
	return XMLParser(data: Data("<d:multistatus xmlns:d=\"DAV:\">\(responses.joined())</d:multistatus>".utf8))
}

extension UnitTests {
	struct PropfindResponseParserTests {
		@Test
		func responseWith403Status() throws {
			let xmlParser = try getXMLParser(forResource: "403-status", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			let elements = try parser.getElements()
			#expect(elements.count == 2)
			let childElements = elements.filter({ $0.depth == 1 })
			#expect(childElements.count == 1)
			let rootURL = try #require(URL(string: "/"))
			let expectedChildElements = try [
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: rootURL)), collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
			]
			#expect(expectedChildElements == childElements)
		}

		@Test
		func responseWithEmptyFolder() throws {
			let xmlParser = try getXMLParser(forResource: "empty-folder", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			let elements = try parser.getElements()
			#expect(elements.count == 1)
			let childElements = elements.filter({ $0.depth == 1 })
			#expect(childElements.isEmpty)
		}

		@Test
		func responseWithFileAndFolder() throws {
			let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			let elements = try parser.getElements()
			#expect(elements.count == 4)
			let childElements = elements.filter({ $0.depth == 1 })
			#expect(childElements.count == 3)
			let rootURL = try #require(URL(string: "/"))
			let expectedChildElements = try [
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/0.txt", relativeTo: rootURL)), collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/1.txt", relativeTo: rootURL)), collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: rootURL)), collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
			]
			#expect(expectedChildElements == childElements)
		}

		@Test
		func responseWithMalformattedDate() throws {
			let xmlParser = try getXMLParser(forResource: "malformatted-date", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			let elements = try parser.getElements()
			#expect(elements.count == 3)
			let childElements = elements.filter({ $0.depth == 1 })
			#expect(childElements.count == 2)
			let rootURL = try #require(URL(string: "/"))
			let expectedChildElements = try [
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/0.txt", relativeTo: rootURL)), collection: false, lastModified: nil, contentLength: 54175),
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: rootURL)), collection: true, lastModified: nil, contentLength: 0)
			]
			#expect(expectedChildElements == childElements)
		}

		@Test
		func responseWithMalformattedXML() throws {
			let xmlParser = try getXMLParser(forResource: "malformatted-xml", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			let error = try #require(throws: (any Error).self, "malformatted xml response") { try parser.getElements() }
			let nsError = error as NSError
			#expect(XMLParser.errorDomain == nsError.domain)
		}

		@Test
		func responseWithMissingHref() throws {
			let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			let elements = try parser.getElements()
			#expect(elements.isEmpty)
		}

		@Test
		func responseWithPartial404Status() throws {
			let xmlParser = try getXMLParser(forResource: "partial-404-status", withExtension: "xml")
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")))
			let elements = try parser.getElements()
			#expect(elements.count == 3)
			let childElements = elements.filter({ $0.depth == 1 })
			#expect(childElements.count == 2)
			let rootURL = try #require(URL(string: "/"))
			let expectedChildElements = try [
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/0.txt", relativeTo: rootURL)), collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
				PropfindResponseElement(depth: 1, url: #require(URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: rootURL)), collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: nil)
			]
			#expect(expectedChildElements == childElements)
		}

		/// The depth counts the segments of the percent-encoded path, so neither an encoded slash nor an escape that isn't valid UTF-8 changes it.
		@Test
		func depthCountsEncodedSegments() throws {
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/file.txt", "/folder/B%FCro.txt", "/folder/a%2Fb", "/folder/sub/deep.txt"])
			let parser = try PropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/file.txt")))
			#expect(try [-1, 0, 0, 0, 1] == parser.getElements().map(\.depth))
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
	}
}
