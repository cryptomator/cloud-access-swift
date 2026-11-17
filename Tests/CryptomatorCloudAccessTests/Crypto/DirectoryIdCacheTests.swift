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
				("/a", ["/ab", "/A/x", "/a_b"]),
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
