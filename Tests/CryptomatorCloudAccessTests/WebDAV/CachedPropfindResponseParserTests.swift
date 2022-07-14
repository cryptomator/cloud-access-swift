//
//  CachedPropfindResponseParserTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 07.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import GRDB
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class CachedPropfindResponseParserTests: XCTestCase {
	var cacheMock: DirectoryContentCacheMock!

	override func setUpWithError() throws {
		cacheMock = DirectoryContentCacheMock()
	}

	func testResponseWith403Status() throws {
		let xmlParser = try getXMLParser(forResource: "403-status", withExtension: "xml")
		let parser = CachePropfindResponseParser(xmlParser, responseURL: URL(string: "/")!, cache: cacheMock, folderEnumerationPath: .root)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveForIndexReceivedInvocations.map { $0.element }
		let savedFolderEnumerationPaths = cacheMock.saveForIndexReceivedInvocations.map { $0.folderEnumerationPath }
		let savedCacheIndices = cacheMock.saveForIndexReceivedInvocations.map { $0.index }
		XCTAssertEqual([
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: 0)
		], savedMetadata)
		XCTAssertEqual([.root], savedFolderEnumerationPaths)
		XCTAssertEqual([1], savedCacheIndices)
		assertCacheNotClearedAndNotFetched()
	}

	func testResponseWithEmptyFolder() throws {
		let xmlParser = try getXMLParser(forResource: "empty-folder", withExtension: "xml")
		let parser = CachePropfindResponseParser(xmlParser, responseURL: URL(string: "/")!, cache: cacheMock, folderEnumerationPath: .root)
		try parser.fillCache()
		XCTAssertFalse(cacheMock.saveForIndexCalled)
		assertCacheNotClearedAndNotFetched()
	}

	func testResponseWithFileAndFolder() throws {
		let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
		let parser = CachePropfindResponseParser(xmlParser, responseURL: URL(string: "/")!, cache: cacheMock, folderEnumerationPath: .root)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveForIndexReceivedInvocations.map { $0.element }
		let savedFolderEnumerationPaths = cacheMock.saveForIndexReceivedInvocations.map { $0.folderEnumerationPath }
		let savedCacheIndices = cacheMock.saveForIndexReceivedInvocations.map { $0.index }
		XCTAssertEqual([
			CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
			CloudItemMetadata(name: "1.txt", cloudPath: .init("/1.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: 0)
		], savedMetadata)
		XCTAssertEqual([.root, .root, .root], savedFolderEnumerationPaths)
		XCTAssertEqual([1, 2, 3], savedCacheIndices)
		assertCacheNotClearedAndNotFetched()
	}

	func testResponseWithMalformattedDate() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-date", withExtension: "xml")
		let parser = CachePropfindResponseParser(xmlParser, responseURL: URL(string: "/")!, cache: cacheMock, folderEnumerationPath: .root)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveForIndexReceivedInvocations.map { $0.element }
		let savedFolderEnumerationPaths = cacheMock.saveForIndexReceivedInvocations.map { $0.folderEnumerationPath }
		let savedCacheIndices = cacheMock.saveForIndexReceivedInvocations.map { $0.index }
		XCTAssertEqual([
			CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: nil, size: 54175),
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: nil, size: 0)
		], savedMetadata)
		XCTAssertEqual([.root, .root], savedFolderEnumerationPaths)
		XCTAssertEqual([1, 2], savedCacheIndices)
		assertCacheNotClearedAndNotFetched()
	}

	func testResponseWithMalformattedXML() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-xml", withExtension: "xml")
		let parser = CachePropfindResponseParser(xmlParser, responseURL: URL(string: "/")!, cache: cacheMock, folderEnumerationPath: .root)
		XCTAssertThrowsError(try parser.fillCache(), "malformatted xml response") { error in
			let nsError = error as NSError
			XCTAssertEqual(XMLParser.errorDomain, nsError.domain)
		}
	}

	func testResponseWithMissingHref() throws {
		let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
		let parser = CachePropfindResponseParser(xmlParser, responseURL: URL(string: "/")!, cache: cacheMock, folderEnumerationPath: .root)
		XCTAssertThrowsError(try parser.fillCache(), "missing href") { error in
			XCTAssertEqual(.itemTypeMismatch, error as? CloudProviderError)
		}
		assertNothingCached()
	}

	func testResponseWithPartial404Status() throws {
		let xmlParser = try getXMLParser(forResource: "partial-404-status", withExtension: "xml")
		let parser = CachePropfindResponseParser(xmlParser, responseURL: URL(string: "/")!, cache: cacheMock, folderEnumerationPath: .root)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveForIndexReceivedInvocations.map { $0.element }
		let savedFolderEnumerationPaths = cacheMock.saveForIndexReceivedInvocations.map { $0.folderEnumerationPath }
		let savedCacheIndices = cacheMock.saveForIndexReceivedInvocations.map { $0.index }
		XCTAssertEqual([
			CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: nil)
		], savedMetadata)
		XCTAssertEqual([.root, .root], savedFolderEnumerationPaths)
		XCTAssertEqual([1, 2], savedCacheIndices)
		assertCacheNotClearedAndNotFetched()
	}

	private func getXMLParser(forResource name: String, withExtension ext: String) throws -> XMLParser {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext), let xmlParser = XMLParser(contentsOf: fileURL) else {
			throw PropfindResponseParserTestsError.missingTestResource
		}
		return xmlParser
	}

	private func assertCacheNotClearedAndNotFetched() {
		XCTAssertFalse(cacheMock.clearCacheForCalled)
		XCTAssertFalse(cacheMock.getResponseForPageTokenCalled)
	}

	private func assertNothingCached() {
		XCTAssertFalse(cacheMock.saveForIndexCalled)
		assertCacheNotClearedAndNotFetched()
	}
}

extension CloudItemMetadata: Equatable {
	public static func == (lhs: CloudItemMetadata, rhs: CloudItemMetadata) -> Bool {
		return lhs.name == rhs.name && lhs.cloudPath == rhs.cloudPath && lhs.itemType == rhs.itemType && lhs.size == rhs.size
	}
}
