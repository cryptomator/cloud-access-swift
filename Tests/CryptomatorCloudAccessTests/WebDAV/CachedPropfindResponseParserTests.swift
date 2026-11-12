//
//  CachedPropfindResponseParserTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 07.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import GRDB
import XCTest
@testable import CryptomatorCloudAccess

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
			XCTAssertEqual(.invalidResponse, error as? WebDAVProviderError)
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

	/// An encoded slash doesn't separate segments, so `/a%2Fb` and `/c%2fd/` are at the folder's depth and `/folder/e%2Ff` is at a child's. They are skipped instead of counting as a second element at the folder's depth or as a child.
	func testResponseSkipsNamesWithEncodedSlash() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/a%2Fb", "/c%2fd/", "/folder/e%2Ff", "/folder/0.txt"])
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
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/sub/deep.txt", "/", "/folder/ok.txt"])
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

	/// The folder stays a folder if its element is repeated without the collection type.
	func testResponseAcceptsRepeatedFolderElement() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder", "/folder/ok.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual(["/folder/ok.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path))
		assertCacheOnlySavedTo()
	}

	/// An href at the folder's depth with a segment that can't be decoded or that holds an encoded slash is skipped, so it doesn't count as a second element at that depth.
	func testResponseSkipsUndecodableAndEncodedSlashElementsAtTheFoldersDepth() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/a/b"))
		for hrefs in [["/a%2Fx/b/", "/a/b/", "/a/b/ok.txt"], ["/a/%FF/", "/a/b/", "/a/b/ok.txt"], ["/a/b/", "/a/x%2Fy", "/a/b/ok.txt"]] {
			cacheMock = DirectoryContentCacheMock()
			let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: XCTUnwrap(URL(string: "/a/b/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			XCTAssertEqual(["/a/b/ok.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path), "\(hrefs)")
		}
	}

	/// An element with an encoded slash in a parent segment is no child of the folder. It is skipped even if it arrives before the folder's own element, when its parent segments can't be compared yet.
	func testResponseSkipsElementsWithEncodedSlashInParentSegment() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		for hrefs in [["/x%2Fy/early.txt", "/folder/", "/folder/ok.txt"], ["/x%2F%CC%81y/early.txt", "/folder/", "/folder/ok.txt"], ["/folder/", "/x%2Fy/late.txt", "/folder/ok.txt"]] {
			cacheMock = DirectoryContentCacheMock()
			let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			XCTAssertEqual(["/folder/ok.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path), "\(hrefs)")
		}
	}

	/// A segment with an encoded slash that decodes to the same as the response URL's at that position is the request's own, so the folder still lists. An element with any other such segment is skipped, even if it arrives before the folder's own element.
	func testResponseCachesElementsOfFolderBelowSegmentWithEncodedSlash() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		for hrefs in [
			["/dav/a%2Fb/folder/", "/dav/a%2fb/folder/ok.txt", "/dav/a%2Fb/folder/c%2Fd", "/dav/a%2Fx/folder/other.txt"],
			["/dav/a%2Fx/folder/other.txt", "/dav/a%2Fb/folder/", "/dav/a%2fb/folder/ok.txt"],
			["/a%2Fb/dav/folder/", "/dav/a%2Fb/folder/", "/dav/a%2fb/folder/ok.txt"]
		] {
			cacheMock = DirectoryContentCacheMock()
			let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: XCTUnwrap(URL(string: "/dav/a%2Fb/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			XCTAssertEqual(["/folder/ok.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path), "\(hrefs)")
			XCTAssertEqual([1], cacheMock.saveInIndexReceivedInvocations.map(\.index), "\(hrefs)")
			assertCacheOnlySavedTo()
		}
	}

	/// A name with an escape that isn't valid UTF-8 (e.g., Latin-1) can't be a cloud path.
	func testResponseSkipsUndecodableChildren() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/B%FCro.txt", "/folder/B%FCro/", "/folder/ok.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
		try parser.fillCache()
		XCTAssertEqual(["/folder/ok.txt"], cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path))
		XCTAssertEqual([1], cacheMock.saveInIndexReceivedInvocations.map(\.index))
		assertCacheOnlySavedTo()
	}

	func testResponseWithUndecodableFolderElementThrows() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/B\u{FC}ro"))
		let xmlParser = getXMLParser(forHrefs: ["/B%FCro/", "/B%FCro/a.txt"])
		let parser = try CachePropfindResponseParser(xmlParser, responseURL: XCTUnwrap(URL(string: "/B%C3%BCro/")), cache: cacheMock, snapshot: snapshot)
		XCTAssertThrowsError(try parser.fillCache()) { error in
			XCTAssertEqual(.invalidResponse, error as? WebDAVProviderError)
		}
		assertNothingCached()
	}

	func testResponseWithFolderElementThatIsNoCollectionThrows() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/file.txt"))
		let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: ["/file.txt"]), responseURL: XCTUnwrap(URL(string: "/file.txt")), cache: cacheMock, snapshot: snapshot)
		XCTAssertThrowsError(try parser.fillCache()) { error in
			XCTAssertEqual(.itemTypeMismatch, error as? CloudProviderError)
		}
		assertNothingCached()
	}

	func testResponseWithSecondElementAtTheFoldersDepthThrows() throws {
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
		for hrefs in [["/other/", "/folder/", "/folder/ok.txt"], ["/folder/", "/up.txt", "/folder/ok.txt"]] {
			let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: XCTUnwrap(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			XCTAssertThrowsError(try parser.fillCache(), "\(hrefs)") { error in
				XCTAssertEqual(.invalidResponse, error as? WebDAVProviderError)
			}
		}
		assertNothingCached()
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
