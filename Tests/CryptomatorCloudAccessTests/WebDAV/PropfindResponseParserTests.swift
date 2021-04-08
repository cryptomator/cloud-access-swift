//
//  PropfindResponseParserTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

enum PropfindResponseParserTestsError: Error {
	case missingTestResource
}

class PropfindResponseParserTests: XCTestCase {
	func testResponseWith403Status() throws {
		let xmlParser = try getXMLParser(forResource: "403-status", withExtension: "xml")
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(2, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(1, childElements.count)
		XCTAssertEqual([
			PropfindResponseElement(depth: 1, url: URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
		], childElements)
	}

	func testResponseWithEmptyFolder() throws {
		let xmlParser = try getXMLParser(forResource: "empty-folder", withExtension: "xml")
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(1, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(0, childElements.count)
	}

	func testResponseWithFileAndFolder() throws {
		let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(3, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(2, childElements.count)
		XCTAssertEqual([
			PropfindResponseElement(depth: 1, url: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
			PropfindResponseElement(depth: 1, url: URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
		], childElements)
	}

	func testResponseWithMalformattedDate() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-date", withExtension: "xml")
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(3, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(2, childElements.count)
		XCTAssertEqual([
			PropfindResponseElement(depth: 1, url: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: nil, contentLength: 54175),
			PropfindResponseElement(depth: 1, url: URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: nil, contentLength: 0)
		], childElements)
	}

	func testResponseWithMalformattedXML() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-xml", withExtension: "xml")
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		XCTAssertThrowsError(try parser.getElements(), "malformatted xml response") { error in
			let nsError = error as NSError
			XCTAssertEqual(XMLParser.errorDomain, nsError.domain)
		}
	}

	func testResponseWithMissingHref() throws {
		let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(0, elements.count)
	}

	func testResponseWithPartial404Status() throws {
		let xmlParser = try getXMLParser(forResource: "partial-404-status", withExtension: "xml")
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(3, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(2, childElements.count)
		XCTAssertEqual([
			PropfindResponseElement(depth: 1, url: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175),
			PropfindResponseElement(depth: 1, url: URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: nil)
		], childElements)
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
