//
//  DirectoryIdCacheTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Sebastian Stenzel on 15.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct DirectoryIdCacheTests {
		let cache: DirectoryIdCache

		init() throws {
			self.cache = try DirectoryIdCache()
		}

		@Test
		func containsRootPath() throws {
			let path = CloudPath("/")

			#expect(try Data([]) == cache.get(path))
		}

		@Test
		func testGet() throws {
			let path = CloudPath("/foo/bar")
			let dirId = Data("foobar".utf8)

			try cache.addOrUpdate(path, dirId: dirId)

			#expect(try dirId == cache.get(path))
		}

		@Test(arguments: ["/..", "one/two"])
		func getOfPathThatNeverReachesRootThrowsItemNotFoundWithoutLookup(path: String) async throws {
			let lookups = OSAllocatedUnfairLock(initialState: 0)
			await #expect(throws: CloudProviderError.itemNotFound) {
				_ = try await cache.get(CloudPath(path), onMiss: { _, _ in
					lookups.withLock { $0 += 1 }
					return Data("ID".utf8)
				})
			}
			#expect(lookups.withLock { $0 } == 0)
		}

		@Test
		func testInvalidate() throws {
			let path = CloudPath("/foo")
			let subPath1 = CloudPath("/foo/bar")
			let subPath2 = CloudPath("/foo/baz")
			let siblingPath = CloudPath("/bar/foo")
			let dirId = Data("foobar".utf8)

			try cache.addOrUpdate(path, dirId: dirId)
			try cache.addOrUpdate(subPath1, dirId: dirId)
			try cache.addOrUpdate(subPath2, dirId: dirId)
			try cache.addOrUpdate(siblingPath, dirId: dirId)
			try cache.invalidate(path)

			#expect(try cache.get(path) == nil)
			#expect(try cache.get(subPath1) == nil)
			#expect(try cache.get(subPath2) == nil)
			#expect(try dirId == cache.get(siblingPath))
		}

		@Test
		func invalidateMatchesPathsLiterally() throws {
			let dirId = Data("foobar".utf8)
			let cases: [(invalidated: String, kept: [String])] = [
				("/a", ["/ab", "/A/x", "/a_b", "/a.", "/a0"]),
				("/a_b", ["/aXb/x"]),
				("/a%", ["/abc"])
			]
			for (invalidated, kept) in cases {
				let cache = try DirectoryIdCache()
				for path in [invalidated, invalidated + "/x"] + kept {
					try cache.addOrUpdate(CloudPath(path), dirId: dirId)
				}

				try cache.invalidate(CloudPath(invalidated))

				#expect(try cache.get(CloudPath(invalidated)) == nil, "\(invalidated)")
				#expect(try cache.get(CloudPath(invalidated + "/x")) == nil, "\(invalidated)")
				for path in kept {
					#expect(try dirId == cache.get(CloudPath(path)), "\(path) after invalidating \(invalidated)")
				}
			}
		}

		@Test
		func invalidateRootRemovesEveryPath() throws {
			try cache.addOrUpdate(CloudPath("/foo/bar"), dirId: Data("foobar".utf8))

			try cache.invalidate(CloudPath("/"))

			#expect(try cache.get(CloudPath("/")) == nil)
			#expect(try cache.get(CloudPath("/foo/bar")) == nil)
		}

		@Test(arguments: [("/cafe\u{301}", "/caf\u{E9}"), ("/caf\u{E9}", "/cafe\u{301}")])
		func keysCanonicallyEquivalentSpellingsAlike(writtenSpelling: String, readSpelling: String) throws {
			let writtenPath = CloudPath(writtenSpelling)
			let readPath = CloudPath(readSpelling)
			let dirId = Data("foobar".utf8)

			try cache.addOrUpdate(writtenPath, dirId: dirId)
			try cache.addOrUpdate(writtenPath.appendingPathComponent("sub"), dirId: dirId)

			#expect(try dirId == cache.get(readPath))
			#expect(try dirId == cache.get(readPath.appendingPathComponent("sub")))
			try cache.invalidate(readPath)
			#expect(try cache.get(writtenPath) == nil)
			#expect(try cache.get(writtenPath.appendingPathComponent("sub")) == nil)
		}

		@Test
		func verifiedDirectoryReadsEachDirFileInItsParentsDirectory() async throws {
			let reads = OSAllocatedUnfairLock(initialState: [String]())
			let directory = try await cache.verifiedDirectory(CloudPath("/one/two/three"), readDirId: { cleartextPath, parentDirId in
				reads.withLock { $0.append("\(cleartextPath.path) in \(String(bytes: parentDirId, encoding: .utf8)!)") }
				return Data(cleartextPath.lastPathComponent.uppercased().utf8)
			}, treatingAsMissing: { _ in false })

			#expect(reads.withLock { $0 } == ["/one in ", "/one/two in ONE", "/one/two/three in TWO"])
			#expect(Data("TWO".utf8) == directory.parentDirId)
			#expect(Data("THREE".utf8) == directory.dirId)
			#expect(directory.containingDirIds == [Data(), Data("ONE".utf8), Data("TWO".utf8)])
			#expect(try Data("TWO".utf8) == cache.get(CloudPath("/one/two")))
		}

		@Test
		func verifiedDirectoryWithAncestorRepeatingDirIdReadsNoFurtherDirFile() async throws {
			let reads = OSAllocatedUnfairLock(initialState: [String]())
			await #expect(throws: VaultFormatError.invalidDirectoryReference) {
				_ = try await cache.verifiedDirectory(CloudPath("/one/two/three"), readDirId: { cleartextPath, _ in
					reads.withLock { $0.append(cleartextPath.path) }
					return Data("ONE".utf8)
				}, treatingAsMissing: { _ in false })
			}
			#expect(reads.withLock { $0 } == ["/one", "/one/two"])
		}

		@Test
		func verifiedDirectoryWithMissingAncestorDirFileThrowsParentFolderDoesNotExist() async throws {
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) {
				_ = try await cache.verifiedDirectory(CloudPath("/one/two"), readDirId: { _, _ in
					throw CloudProviderError.itemNotFound
				}, treatingAsMissing: { _ in true })
			}
		}

		@Test
		func verifiedDirectoryWithMissingDirFileReturnsNoDirId() async throws {
			let directory = try await cache.verifiedDirectory(CloudPath("/one/two"), readDirId: { cleartextPath, _ in
				guard cleartextPath.lastPathComponent == "one" else {
					throw CloudProviderError.itemNotFound
				}
				return Data("ONE".utf8)
			}, treatingAsMissing: { error in error as? CloudProviderError == .itemNotFound })

			#expect(Data("ONE".utf8) == directory.parentDirId)
			#expect(directory.dirId == nil)
			#expect(directory.containingDirIds == [Data(), Data("ONE".utf8)])
		}

		@Test(arguments: ["/", "/..", "one/two"])
		func verifiedDirectoryRejectsPathNamingNoFolderBelowRoot(path: String) async throws {
			let reads = OSAllocatedUnfairLock(initialState: 0)
			await #expect(throws: VaultFormatError.invalidDirectoryReference) {
				_ = try await cache.verifiedDirectory(CloudPath(path), readDirId: { _, _ in
					reads.withLock { $0 += 1 }
					return Data("ID".utf8)
				}, treatingAsMissing: { _ in false })
			}
			#expect(reads.withLock { $0 } == 0)
		}

		/// Another device moved the folder away and created a new one at its path, which the cache doesn't know.
		@Test(arguments: ["/one", "/one/two"])
		func verifiedDirectoryWithStaleCachedDirIdInvalidatesPathAndThrowsItemNotFound(path: String) async throws {
			try cache.addOrUpdate(CloudPath("/one"), dirId: Data("OLD".utf8))
			try cache.addOrUpdate(CloudPath("/one/sub"), dirId: Data("SUB".utf8))
			let reads = OSAllocatedUnfairLock(initialState: [String]())
			await #expect(throws: CloudProviderError.itemNotFound) {
				_ = try await cache.verifiedDirectory(CloudPath(path), readDirId: { cleartextPath, _ in
					reads.withLock { $0.append(cleartextPath.path) }
					return Data(cleartextPath.lastPathComponent.uppercased().utf8)
				}, treatingAsMissing: { _ in false })
			}
			#expect(reads.withLock { $0 } == ["/one"])
			#expect(try cache.get(CloudPath("/one")) == nil)
			#expect(try cache.get(CloudPath("/one/sub")) == nil)
		}

		@Test(arguments: ["", "ONE"])
		func verifiedDirectoryWithDirIdRepeatingContainingOneThrowsInvalidDirectoryReference(repeatedDirId: String) async throws {
			await #expect(throws: VaultFormatError.invalidDirectoryReference) {
				_ = try await cache.verifiedDirectory(CloudPath("/one/two"), readDirId: { cleartextPath, _ in
					return Data((cleartextPath.lastPathComponent == "one" ? "ONE" : repeatedDirId).utf8)
				}, treatingAsMissing: { _ in false })
			}
			#expect(try cache.get(CloudPath("/one/two")) == nil)
		}

		/// The dir IDs read before the cancelled read stay cached, and the cancelled read changes nothing, although its ID differs from the cached one.
		@Test(arguments: ["/one", "/one/two"])
		func verifiedDirectoryCancelledDuringReadKeepsCache(cancelledReadPath: String) async throws {
			try cache.addOrUpdate(CloudPath(cancelledReadPath), dirId: Data("OLD".utf8))
			let cache: DirectoryIdCache = cache
			let verification = Task {
				_ = try await cache.verifiedDirectory(CloudPath("/one/two"), readDirId: { cleartextPath, _ in
					if cleartextPath.path == cancelledReadPath {
						withUnsafeCurrentTask { $0?.cancel() }
					}
					return Data(cleartextPath.lastPathComponent.uppercased().utf8)
				}, treatingAsMissing: { _ in false })
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: verification) }
			#expect(try Data("OLD".utf8) == cache.get(CloudPath(cancelledReadPath)))
			if cancelledReadPath == "/one/two" {
				#expect(try Data("ONE".utf8) == cache.get(CloudPath("/one")))
			} else {
				#expect(try cache.get(CloudPath("/one/two")) == nil)
			}
		}

		@Test
		func recursiveGet() async throws {
			let path = CloudPath("/one/two/three")

			let misses = OSAllocatedUnfairLock(initialState: [String]())
			let data = try await cache.get(path, onMiss: { cleartextPath, parentDirId in
				let dirId: String = {
					switch cleartextPath.lastPathComponent {
					case "one":
						#expect(Data() == parentDirId)
						return "ONE"
					case "two":
						#expect(Data("ONE".utf8) == parentDirId)
						return "TWO"
					case "three":
						#expect(Data("TWO".utf8) == parentDirId)
						return "THREE"
					default:
						Issue.record("Unexpected path component: \(cleartextPath.lastPathComponent)")
						return "UNEXPECTED"
					}
				}()
				misses.withLock { $0.append(dirId) }
				return Data(dirId.utf8)
			})
			#expect(Data("THREE".utf8) == data)

			#expect(misses.withLock { $0 } == ["ONE", "TWO", "THREE"])
		}
	}
}
