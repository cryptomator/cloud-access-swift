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
	let snapshot = DirectoryContentSnapshot(folderEnumerationPath: .root)

	override func setUpWithError() throws {
		cacheMock = DirectoryContentCacheMock()
	}

	func testResponseWith403Status() throws {
		let xmlParser = try getXMLParser(forResource: "403-status", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
		let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
		let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
		XCTAssertEqual([
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: 0)
		], savedMetadata)
		XCTAssertEqual([snapshot.id], savedSnapshotIDs)
		XCTAssertEqual([1], savedCacheIndices)
		assertCacheOnlySavedTo()
	}

	func testResponseWithEmptyFolder() throws {
		let xmlParser = try getXMLParser(forResource: "empty-folder", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertFalse(cacheMock.saveInIndexCalled)
		assertCacheOnlySavedTo()
	}

	func testResponseWithFileAndFolder() throws {
		let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
		let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
		let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
		XCTAssertEqual([
			CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
			CloudItemMetadata(name: "1.txt", cloudPath: .init("/1.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: 0)
		], savedMetadata)
		XCTAssertEqual([snapshot.id, snapshot.id, snapshot.id], savedSnapshotIDs)
		XCTAssertEqual([1, 2, 3], savedCacheIndices)
		assertCacheOnlySavedTo()
	}

	func testResponseWithMalformattedDate() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-date", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
		let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
		let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
		XCTAssertEqual([
			CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: nil, size: 54175),
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: nil, size: 0)
		], savedMetadata)
		XCTAssertEqual([snapshot.id, snapshot.id], savedSnapshotIDs)
		XCTAssertEqual([1, 2], savedCacheIndices)
		assertCacheOnlySavedTo()
	}

	func testResponseWithCachingError() throws {
		cacheMock.saveInIndexClosure = { _, _, index in
			if index == 2 {
				throw CachingError.saveFailed
			}
		}
		let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		XCTAssertThrowsError(try parser.fillCache(), "caching error") { error in
			XCTAssertEqual(.saveFailed, error as? CachingError)
		}
		XCTAssertEqual([1, 2], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	func testResponseWithMalformattedXML() throws {
		let xmlParser = try getXMLParser(forResource: "malformatted-xml", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		XCTAssertThrowsError(try parser.fillCache(), "malformatted xml response") { error in
			let nsError = error as NSError
			XCTAssertEqual(XMLParser.errorDomain, nsError.domain)
		}
	}

	func testResponseWithMissingHref() throws {
		let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		XCTAssertThrowsError(try parser.fillCache(), "missing href") { error in
			XCTAssertEqual(.itemTypeMismatch, error as? CloudProviderError)
		}
		assertNothingCached()
	}

	func testResponseWithPartial404Status() throws {
		let xmlParser = try getXMLParser(forResource: "partial-404-status", withExtension: "xml")
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
		let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
		let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
		XCTAssertEqual([
			CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
			CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: nil)
		], savedMetadata)
		XCTAssertEqual([snapshot.id, snapshot.id], savedSnapshotIDs)
		XCTAssertEqual([1, 2], savedCacheIndices)
		assertCacheOnlySavedTo()
	}

	func testResponseSkipsNamesThatAreNoSinglePathComponent() throws {
		let xmlParser = getXMLParser(forHrefs: ["/", "/%2E%2E", "/%2e/", "/0.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual([CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: nil, size: nil)], cacheMock.saveInIndexReceivedInvocations.map(\.element))
		XCTAssertEqual([1], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	/// An href with an encoded slash reaches the name check only if it lies outside the folder, because only then is its decoded path one level deeper than the folder.
	func testResponseSkipsNamesWithEncodedSlash() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/a%2Fb", "/c%2fd/", "/folder/0.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual([CloudItemMetadata(name: "0.txt", cloudPath: .init("/folder/0.txt"), itemType: .file, lastModifiedDate: nil, size: nil)], cacheMock.saveInIndexReceivedInvocations.map(\.element))
		XCTAssertEqual([1], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	func testResponseCachesNameStartingWithCombiningMark() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/%CC%81report.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual(["\u{301}report.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.name))
		XCTAssertEqual(["/folder/\u{301}report.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path))
		assertCacheOnlySavedTo()
	}

	func testResponseSkipsElementsThatAreNotOneLevelDeeper() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/sub/deep.txt", "/up.txt", "/folder/", "/folder/ok.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual([CloudItemMetadata(name: "ok.txt", cloudPath: .init("/folder/ok.txt"), itemType: .file, lastModifiedDate: nil, size: nil)], cacheMock.saveInIndexReceivedInvocations.map(\.element))
		XCTAssertEqual([1], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	func testResponseSkipsElementsOutsideTheFolder() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/other/sibling.txt", "/folder/ok.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual([CloudItemMetadata(name: "ok.txt", cloudPath: .init("/folder/ok.txt"), itemType: .file, lastModifiedDate: nil, size: nil)], cacheMock.saveInIndexReceivedInvocations.map(\.element))
		XCTAssertEqual([1], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	/// The server spells the folder decomposed, unlike the request, and its hrefs differ too: lowercase escapes (a), an absolute URI in the request's spelling (b), a doubled slash (c) and a relative href (d).
	func testResponseCachesElementsOfFolderInAnotherSpelling() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/B\u{FC}ro"))
		let xmlParser = getXMLParser(forHrefs: ["/Bu%CC%88ro/", "/Bu%cc%88ro/a.txt", "http://example.com/B%C3%BCro/b.txt", "/Bu%CC%88ro//c.txt", "d.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "http://example.com/B%C3%BCro/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual(["a.txt", "b.txt", "c.txt", "d.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.name))
		XCTAssertEqual([1, 2, 3, 4], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	func testResponseCachesElementsBeforeTheFoldersOwnElement() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/early.txt", "/folder/", "/folder/late.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual(["early.txt", "late.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.name))
		XCTAssertEqual([1, 2], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	/// An href that ends with a slash is a collection.
	private func getXMLParser(forHrefs hrefs: [String]) -> XMLParser {
		let responses = hrefs.map { href in
			let resourceType = href.hasSuffix("/") ? "<d:collection />" : ""
			return "<d:response><d:href>\(href)</d:href><d:propstat><d:prop><d:resourcetype>\(resourceType)</d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"
		}
		return XMLParser(data: Data("<d:multistatus xmlns:d=\"DAV:\">\(responses.joined())</d:multistatus>".utf8))
	}

	private func getXMLParser(forResource name: String, withExtension ext: String) throws -> XMLParser {
		let testBundle = Bundle(for: type(of: self))
		guard let fileURL = testBundle.url(forResource: name, withExtension: ext), let xmlParser = XMLParser(contentsOf: fileURL) else {
			throw PropfindResponseParserTestsError.missingTestResource
		}
		return xmlParser
	}

	private enum CachingError: Error {
		case saveFailed
	}

	private func assertCacheOnlySavedTo() {
		XCTAssertFalse(cacheMock.discardCalled)
		XCTAssertFalse(cacheMock.publishCalled)
		XCTAssertFalse(cacheMock.getPageForPageTokenCalled)
	}

	private func assertNothingCached() {
		XCTAssertFalse(cacheMock.saveInIndexCalled)
		assertCacheOnlySavedTo()
	}
}

extension CloudItemMetadata: @retroactive Equatable {
	public static func == (lhs: CloudItemMetadata, rhs: CloudItemMetadata) -> Bool {
		return lhs.name == rhs.name && lhs.cloudPath == rhs.cloudPath && lhs.itemType == rhs.itemType && lhs.size == rhs.size
	}
}
