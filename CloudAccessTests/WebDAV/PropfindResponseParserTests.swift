//
//  PropfindResponseParserTests.swift
//  CloudAccessTests
//
//  Created by Tobias Hagemann on 13.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
@testable import CloudAccess

class PropfindResponseParserTests: XCTestCase {
	let testFolder = PropfindResponseElement(depth: 1, href: URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), contentLength: 0)
	let testFile = PropfindResponseElement(depth: 1, href: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), contentLength: 54175)

	func testResponseWith403Status() throws {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: "403-status", withExtension: "xml"), let xmlParser = XMLParser(contentsOf: fileURL) else {
			XCTFail("Unable to open mock XML response")
			return
		}
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(2, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(1, childElements.count)
		XCTAssertEqual([testFolder], childElements)
	}

	func testResponseWithEmptyFolder() throws {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: "empty-folder", withExtension: "xml"), let xmlParser = XMLParser(contentsOf: fileURL) else {
			XCTFail("Unable to open mock XML response")
			return
		}
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/asdasdasd/d/OC/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(1, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(0, childElements.count)
	}

	func testResponseWithFileAndFolder() throws {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: "file-and-folder", withExtension: "xml"), let xmlParser = XMLParser(contentsOf: fileURL) else {
			XCTFail("Unable to open mock XML response")
			return
		}
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(3, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(2, childElements.count)
		XCTAssertEqual([testFile, testFolder], childElements)
	}

	func testResponseWithMalformattedDate() throws {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: "malformatted-date", withExtension: "xml"), let xmlParser = XMLParser(contentsOf: fileURL) else {
			XCTFail("Unable to open mock XML response")
			return
		}
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(3, elements.count)
		let childElements = elements.filter({ $0.depth == 1 })
		XCTAssertEqual(2, childElements.count)
		XCTAssertEqual([
			PropfindResponseElement(depth: 1, href: URL(string: "/0.txt", relativeTo: URL(string: "/")!)!, collection: false, lastModified: nil, contentLength: 54175),
			PropfindResponseElement(depth: 1, href: URL(string: "/Gel%c3%b6schte%20Dateien/", relativeTo: URL(string: "/")!)!, collection: true, lastModified: nil, contentLength: 0)
		], childElements)
	}

	func testResponseWithMalformattedXML() throws {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: "malformatted-xml", withExtension: "xml"), let xmlParser = XMLParser(contentsOf: fileURL) else {
			XCTFail("Unable to open mock XML response")
			return
		}
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		XCTAssertThrowsError(try parser.getElements(), "malformatted xml response") { error in
			let nsError = error as NSError
			XCTAssertEqual(XMLParser.errorDomain, nsError.domain)
		}
	}

	func testResponseWithMissingHref() throws {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: "missing-href", withExtension: "xml"), let xmlParser = XMLParser(contentsOf: fileURL) else {
			XCTFail("Unable to open mock XML response")
			return
		}
		let parser = PropfindResponseParser(xmlParser, responseURL: URL(string: "/")!)
		let elements = try parser.getElements()
		XCTAssertEqual(0, elements.count)
	}
}
