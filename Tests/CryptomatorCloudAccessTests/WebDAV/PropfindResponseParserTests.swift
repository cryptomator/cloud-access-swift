//
//  PropfindResponseParserTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
@testable import CryptomatorCloudAccess

enum PropfindResponseParserTestsError: Error {
	case missingTestResource
}

extension XCTestCase {
	/// An href that ends with a slash is a collection.
	func getXMLParser(forHrefs hrefs: [String]) -> XMLParser {
		let responses = hrefs.map { href in
			let resourceType = href.hasSuffix("/") ? "<d:collection />" : ""
			return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(resourceType)</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
		}
		return XMLParser(data: Data("<d:multistatus xmlns:d=\"DAV:\">\(responses.joined())</d:multistatus>".utf8))
	}
}

class PropfindResponseParserTests: XCTestCase {
	func testResponseWith403Status() throws {
		let xmlParser = try getXMLParser(forResource: "403-status", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		let elements = try parser.getElements()
		XCTAssertEqual(2, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(1, childElements.count)
		XCTAssertEqual(try [
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: XCTUnwrap(URL(string: "/")))), collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
		], childElements)
	}

	func testResponseWithEmptyFolder() throws {
		let xmlParser = try getXMLParser(forResource: "empty-folder", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		let elements = try parser.getElements()
		XCTAssertEqual(1, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(0, childElements.count)
	}

	func testResponseWithFileAndFolder() throws {
		let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		let elements = try parser.getElements()
		XCTAssertEqual(4, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(3, childElements.count)
		XCTAssertEqual(try [
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/0.txt", relativeTo: XCTUnwrap(URL(string: "/")))), collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/1.txt", relativeTo: XCTUnwrap(URL(string: "/")))), collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: XCTUnwrap(URL(string: "/")))), collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
		], childElements)
	}

	func testResponseWithMalformattedDate() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-date", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		let elements = try parser.getElements()
		XCTAssertEqual(3, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(2, childElements.count)
		XCTAssertEqual(try [
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/0.txt", relativeTo: XCTUnwrap(URL(string: "/")))), collection: false, lastModified: nil, contentLength: 54175),
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: XCTUnwrap(URL(string: "/")))), collection: true, lastModified: nil, contentLength: 0)
		], childElements)
	}

	func testResponseWithMalformattedXML() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-xml", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		XCTAssertThrowsError(try parser.getElements(), "malformatted xml response") { error in
			let nsError = error as NSError
			XCTAssertEqual(XMLParser.errorDomain, nsError.domain)
		}
	}

	func testResponseWithMissingHref() throws {
		let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		let elements = try parser.getElements()
		XCTAssertEqual(0, elements.count)
	}

	func testResponseWithPartial404Status() throws {
		let xmlParser = try getXMLParser(forResource: "partial-404-status", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		let elements = try parser.getElements()
		XCTAssertEqual(3, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(2, childElements.count)
		XCTAssertEqual(try [
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/0.txt", relativeTo: XCTUnwrap(URL(string: "/")))), collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
			PropfindResponseElement(depth: 1, url: XCTUnwrap(try URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: XCTUnwrap(URL(string: "/")))), collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: nil)
		], childElements)
	}

	/// The depth counts the segments of the percent-encoded path, so neither an encoded slash nor an escape that isn't valid UTF-8 changes it.
	func testDepthCountsEncodedSegments() throws {
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/file.txt", "/folder/B%FCro.txt", "/folder/a%2Fb", "/folder/sub/deep.txt"])
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/file.txt")))
		XCTAssertEqual([-1, 0, 0, 0, 1], try parser.getElements().map(\.depth))
	}

	/// The requested element is listed after another element of its depth and spells its path with an escape.
	func testGetRequestedElementPrefersElementWithPathOfResponseURL() throws {
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/other.txt", "/folder/file%2Etxt"])
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/file.txt")))
		XCTAssertEqual("/folder/file.txt", try parser.getRequestedElement()?.url.path)
	}

	/// A proxy that removes a prefix from the path leaves a child of the requested folder at the depth of the response URL.
	func testGetRequestedElementFallsBackToFirstElement() throws {
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/file.txt"])
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/proxy/folder/")))
		XCTAssertEqual("/folder", try parser.getRequestedElement()?.url.path)
	}

	func testGetRequestedElementWithUndecodableResponseURLTakesFirstElement() throws {
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/%E4.txt"])
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/%E4.txt")))
		XCTAssertEqual("/folder", try parser.getRequestedElement()?.url.path)
	}

	func testGetRequestedElementWithoutElements() throws {
		let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
		let parser = try PropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")))
		XCTAssertNil(try parser.getRequestedElement())
	}

	// MARK: - Internal

	private func getXMLParser(forResource name: String, withExtension ext: String) throws -> XMLParser {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext), let xmlParser = XMLParser(contentsOf: fileURL) else {
			throw PropfindResponseParserTestsError.missingTestResource
		}
		return xmlParser
	}
}
