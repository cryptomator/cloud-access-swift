//
//  CachedPropfindResponseParserTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 07.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class CachedPropfindResponseParserTests {
		var cacheMock = DirectoryContentCacheMock()
		let snapshot = DirectoryContentSnapshot(folderEnumerationPath: .root)

		@Test
		func responseWith403Status() throws {
			let xmlParser = try getXMLParser(forResource: "403-status", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
			let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
			let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
			#expect([
				CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: 0)
			] == savedMetadata)
			#expect([snapshot.id] == savedSnapshotIDs)
			#expect(savedCacheIndices == [1])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseWithEmptyFolder() throws {
			let xmlParser = try getXMLParser(forResource: "empty-folder", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect(!cacheMock.saveInIndexCalled)
			assertCacheOnlySavedTo()
		}

		@Test
		func responseWithFileAndFolder() throws {
			let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
			let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
			let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
			#expect([
				CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
				CloudItemMetadata(name: "1.txt", cloudPath: .init("/1.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
				CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: 0)
			] == savedMetadata)
			#expect([snapshot.id, snapshot.id, snapshot.id] == savedSnapshotIDs)
			#expect(savedCacheIndices == [1, 2, 3])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseWithMalformattedDate() throws {
			let xmlParser = try getXMLParser(forResource: "malformatted-date", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
			let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
			let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
			#expect([
				CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: nil, size: 54175),
				CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: nil, size: 0)
			] == savedMetadata)
			#expect([snapshot.id, snapshot.id] == savedSnapshotIDs)
			#expect(savedCacheIndices == [1, 2])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseWithCachingError() throws {
			cacheMock.saveInIndexClosure = { _, _, index in
				if index == 2 {
					throw CachingError.saveFailed
				}
			}
			let xmlParser = try getXMLParser(forResource: "file-and-folder", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			#expect(throws: CachingError.saveFailed, "caching error") { try parser.fillCache() }
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1, 2])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseWithMalformattedXML() throws {
			let xmlParser = try getXMLParser(forResource: "malformatted-xml", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			let error = try #require(throws: (any Error).self, "malformatted xml response") { try parser.fillCache() }
			let nsError = error as NSError
			#expect(XMLParser.errorDomain == nsError.domain)
		}

		@Test
		func responseWithMissingHref() throws {
			let xmlParser = try getXMLParser(forResource: "missing-href", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			#expect(throws: WebDAVProviderError.invalidResponse, "missing href") { try parser.fillCache() }
			assertNothingCached()
		}

		@Test
		func responseWithPartial404Status() throws {
			let xmlParser = try getXMLParser(forResource: "partial-404-status", withExtension: "xml")
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			let savedMetadata = cacheMock.saveInIndexReceivedInvocations.map(\.element)
			let savedSnapshotIDs = cacheMock.saveInIndexReceivedInvocations.map(\.snapshot.id)
			let savedCacheIndices = cacheMock.saveInIndexReceivedInvocations.map(\.index)
			#expect([
				CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 9:49:41 GMT"), size: 54175),
				CloudItemMetadata(name: "Gelöschte Dateien", cloudPath: .init("/Gelöschte Dateien"), itemType: .folder, lastModifiedDate: Date.date(fromRFC822: "Thu, 18 May 2017 09:51:59 GMT"), size: nil)
			] == savedMetadata)
			#expect([snapshot.id, snapshot.id] == savedSnapshotIDs)
			#expect(savedCacheIndices == [1, 2])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseSkipsNamesThatAreNoSinglePathComponent() throws {
			let xmlParser = getXMLParser(forHrefs: ["/", "/%2E%2E", "/%2e/", "/0.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect([CloudItemMetadata(name: "0.txt", cloudPath: .init("/0.txt"), itemType: .file, lastModifiedDate: nil, size: nil)] == cacheMock.saveInIndexReceivedInvocations.map(\.element))
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1])
			assertCacheOnlySavedTo()
		}

		/// An encoded slash doesn't separate segments, so `/a%2Fb` and `/c%2fd/` are at the folder's depth and `/folder/e%2Ff` is at a child's. They are skipped instead of counting as a second element at the folder's depth or as a child.
		@Test
		func responseSkipsNamesWithEncodedSlash() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/a%2Fb", "/c%2fd/", "/folder/e%2Ff", "/folder/0.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect([CloudItemMetadata(name: "0.txt", cloudPath: .init("/folder/0.txt"), itemType: .file, lastModifiedDate: nil, size: nil)] == cacheMock.saveInIndexReceivedInvocations.map(\.element))
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseCachesNameStartingWithCombiningMark() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/%CC%81report.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.name) == ["\u{301}report.txt"])
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path) == ["/folder/\u{301}report.txt"])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseSkipsElementsThatAreNotOneLevelDeeper() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/sub/deep.txt", "/", "/folder/ok.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect([CloudItemMetadata(name: "ok.txt", cloudPath: .init("/folder/ok.txt"), itemType: .file, lastModifiedDate: nil, size: nil)] == cacheMock.saveInIndexReceivedInvocations.map(\.element))
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseSkipsElementsOutsideTheFolder() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/other/sibling.txt", "/folder/ok.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect([CloudItemMetadata(name: "ok.txt", cloudPath: .init("/folder/ok.txt"), itemType: .file, lastModifiedDate: nil, size: nil)] == cacheMock.saveInIndexReceivedInvocations.map(\.element))
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1])
			assertCacheOnlySavedTo()
		}

		/// The folder stays a folder if its element is repeated without the collection type.
		@Test
		func responseAcceptsRepeatedFolderElement() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder", "/folder/ok.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path) == ["/folder/ok.txt"])
			assertCacheOnlySavedTo()
		}

		/// An href at the folder's depth with a segment that can't be decoded or that holds an encoded slash is skipped, so it doesn't count as a second element at that depth.
		@Test
		func responseSkipsUndecodableAndEncodedSlashElementsAtTheFoldersDepth() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/a/b"))
			for hrefs in [["/a%2Fx/b/", "/a/b/", "/a/b/ok.txt"], ["/a/%FF/", "/a/b/", "/a/b/ok.txt"], ["/a/b/", "/a/x%2Fy", "/a/b/ok.txt"]] {
				cacheMock = DirectoryContentCacheMock()
				let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: #require(URL(string: "/a/b/")), cache: cacheMock, snapshot: snapshot)
				try parser.fillCache()
				#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path) == ["/a/b/ok.txt"], "\(hrefs)")
			}
		}

		/// An element with an encoded slash in a parent segment is no child of the folder. It is skipped even if it arrives before the folder's own element, when its parent segments can't be compared yet.
		@Test
		func responseSkipsElementsWithEncodedSlashInParentSegment() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			for hrefs in [["/x%2Fy/early.txt", "/folder/", "/folder/ok.txt"], ["/x%2F%CC%81y/early.txt", "/folder/", "/folder/ok.txt"], ["/folder/", "/x%2Fy/late.txt", "/folder/ok.txt"]] {
				cacheMock = DirectoryContentCacheMock()
				let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
				try parser.fillCache()
				#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path) == ["/folder/ok.txt"], "\(hrefs)")
			}
		}

		/// A segment with an encoded slash that decodes to the same as the response URL's at that position is the request's own, so the folder still lists. An element with any other such segment is skipped, even if it arrives before the folder's own element.
		@Test
		func responseCachesElementsOfFolderBelowSegmentWithEncodedSlash() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			for hrefs in [
				["/dav/a%2Fb/folder/", "/dav/a%2fb/folder/ok.txt", "/dav/a%2Fb/folder/c%2Fd", "/dav/a%2Fx/folder/other.txt"],
				["/dav/a%2Fx/folder/other.txt", "/dav/a%2Fb/folder/", "/dav/a%2fb/folder/ok.txt"],
				["/a%2Fb/dav/folder/", "/dav/a%2Fb/folder/", "/dav/a%2fb/folder/ok.txt"]
			] {
				cacheMock = DirectoryContentCacheMock()
				let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: #require(URL(string: "/dav/a%2Fb/folder/")), cache: cacheMock, snapshot: snapshot)
				try parser.fillCache()
				#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path) == ["/folder/ok.txt"], "\(hrefs)")
				#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1], "\(hrefs)")
				assertCacheOnlySavedTo()
			}
		}

		/// A name with an escape that isn't valid UTF-8 (e.g., Latin-1) can't be a cloud path.
		@Test
		func responseSkipsUndecodableChildren() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			let xmlParser = getXMLParser(forHrefs: ["/folder/", "/folder/B%FCro.txt", "/folder/B%FCro/", "/folder/ok.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.cloudPath.path) == ["/folder/ok.txt"])
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseWithUndecodableFolderElementThrows() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/B\u{FC}ro"))
			let xmlParser = getXMLParser(forHrefs: ["/B%FCro/", "/B%FCro/a.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/B%C3%BCro/")), cache: cacheMock, snapshot: snapshot)
			#expect(throws: WebDAVProviderError.invalidResponse) { try parser.fillCache() }
			assertNothingCached()
		}

		@Test
		func responseWithFolderElementThatIsNoCollectionThrows() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/file.txt"))
			let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: ["/file.txt"]), responseURL: #require(URL(string: "/file.txt")), cache: cacheMock, snapshot: snapshot)
			#expect(throws: CloudProviderError.itemTypeMismatch) { try parser.fillCache() }
			assertNothingCached()
		}

		@Test
		func responseWithSecondElementAtTheFoldersDepthThrows() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			for hrefs in [["/other/", "/folder/", "/folder/ok.txt"], ["/folder/", "/up.txt", "/folder/ok.txt"]] {
				let parser = try CachePropfindResponseParser(getXMLParser(forHrefs: hrefs), responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
				#expect(throws: WebDAVProviderError.invalidResponse, "\(hrefs)") { try parser.fillCache() }
			}
			assertNothingCached()
		}

		/// The server spells the folder decomposed, unlike the request, and its hrefs differ too: lowercase escapes (a), an absolute URI in the request's spelling (b), a doubled slash (c) and a relative href (d).
		@Test
		func responseCachesElementsOfFolderInAnotherSpelling() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/B\u{FC}ro"))
			let xmlParser = getXMLParser(forHrefs: ["/Bu%CC%88ro/", "/Bu%cc%88ro/a.txt", "http://example.com/B%C3%BCro/b.txt", "/Bu%CC%88ro//c.txt", "d.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "http://example.com/B%C3%BCro/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.name) == ["a.txt", "b.txt", "c.txt", "d.txt"])
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1, 2, 3, 4])
			assertCacheOnlySavedTo()
		}

		@Test
		func responseCachesElementsBeforeTheFoldersOwnElement() throws {
			let snapshot = DirectoryContentSnapshot(folderEnumerationPath: CloudPath("/folder"))
			let xmlParser = getXMLParser(forHrefs: ["/folder/early.txt", "/folder/", "/folder/late.txt"])
			let parser = try CachePropfindResponseParser(xmlParser, responseURL: #require(URL(string: "/folder/")), cache: cacheMock, snapshot: snapshot)
			try parser.fillCache()
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.element.name) == ["early.txt", "late.txt"])
			#expect(cacheMock.saveInIndexReceivedInvocations.map(\.index) == [1, 2])
			assertCacheOnlySavedTo()
		}

		private func assertCacheOnlySavedTo() {
			#expect(!cacheMock.discardCalled)
			#expect(!cacheMock.publishCalled)
			#expect(!cacheMock.getPageForPageTokenCalled)
		}

		private func assertNothingCached() {
			#expect(!cacheMock.saveInIndexCalled)
			assertCacheOnlySavedTo()
		}
	}
}

private enum CachingError: Error {
	case saveFailed
}
