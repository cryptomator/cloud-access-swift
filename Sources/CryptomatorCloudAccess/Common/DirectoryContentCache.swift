//
//  DirectoryContentCache.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 08.07.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import GRDB

protocol DirectoryContentCache {
	/**
	 Caches the given element for the given `folderEnumerationPath` and cacheIndex.

	 - Parameter element: The element to be cached.
	 - Parameter folderEnumerationPath: The path of the parent folder where the `element` is located.
	 - Parameter index: The cache index with which the item should be stored. Each `folderEnumerationPath` has its own cache index, which starts at 1.
	 */
	func save(_ element: CloudItemMetadata, for folderEnumerationPath: CloudPath, index: Int64) throws

	/**
	 Clears the cached elements which belong to the given `folderEnumerationPath`.
	 */
	func clearCache(for folderEnumerationPath: CloudPath) throws

	/**
	 Returns a cache response containing the cached `CloudItemMetadata` elements for the given folder cloud path and page token.

	 The `CloudItemMetadata` elements contained in the CacheResponse are sorted by name.
	 In addition, the number of elements in a `CacheResponse` never exceeds the initially specified `maxPageSize`.
	 Thus it is possible to perform a paginated  folder content listing (with the cached elements).
	 This is useful, for example, to perform folder listing for folders that have a lot of child items without using a lot of RAM.
	 - Parameter folderPath: the folder path for which the elements were cached.
	 - Parameter pageToken: (Optional) The page token  specifies which range of cached items should be returned for this folder path.
	 The returned `CacheResponse` always contains the successive page token. A page token has the following format: `startCacheIndex:endCacheIndex`.
	 */
	func getResponse(for folderPath: CloudPath, pageToken: String?) throws -> DirectoryContentCacheResponse
}

struct DirectoryContentCacheResponse {
	let elements: [CloudItemMetadata]
	let nextPageToken: String?
}

struct DirectoryContentDBCache: DirectoryContentCache {
	let dbWriter: DatabaseWriter
	let maxPageSize: Int
	private let cachedStatement: Statement

	private static var migrator: DatabaseMigrator {
		var migrator = DatabaseMigrator()
		migrator.registerMigration("initial") { db in
			try db.create(table: "entries", body: { table in
				table.column("id", .integer).primaryKey(autoincrement: true)
				table.column("cacheIndex", .integer).notNull().indexed()
				table.column("name", .text).notNull()
				table.column("folderEnumerationPath", .text).notNull()
				table.column("itemType", .text).notNull()
				table.column("lastModified", .double)
				table.column("size", .integer)
			})
		}
		return migrator
	}

	init(dbWriter: DatabaseWriter, maxPageSize: Int) throws {
		self.dbWriter = dbWriter
		self.maxPageSize = maxPageSize
		try DirectoryContentDBCache.migrator.migrate(dbWriter)
		self.cachedStatement = try dbWriter.write { db in
			return try db.cachedStatement(sql: "INSERT INTO entries (cacheIndex, name, itemType, lastModified, size, folderEnumerationPath) VALUES (?, ?, ?, ?, ?, ?)")
		}
		// reduce the cache size from 2000 KiB to 500 KiB
		try dbWriter.write { db in
			try db.execute(sql: "pragma cache_size = -500")
		}
	}

	func save(_ element: CloudItemMetadata, for folderEnumerationPath: CloudPath, index: Int64) throws {
		try autoreleasepool {
			_ = try dbWriter.write { _ in
				try cachedStatement.execute(arguments: [index, element.name, element.itemType, element.lastModifiedDate?.timeIntervalSinceReferenceDate, element.size, folderEnumerationPath])
			}
		}
	}

	func clearCache(for folderEnumerationPath: CloudPath) throws {
		let request = CacheElement.filter(CacheElement.Columns.folderEnumerationPath == folderEnumerationPath)
		_ = try dbWriter.write { db in
			try request.deleteAll(db)
		}
	}

	func getResponse(for folderPath: CloudPath, pageToken: String?) throws -> DirectoryContentCacheResponse {
		let convertedPageToken: PageToken
		if let pageToken = pageToken {
			let components = pageToken.components(separatedBy: ":")
			guard components.count == 2, let minID = Int(components[0]), let maxID = Int(components[1]) else {
				throw CloudProviderError.pageTokenInvalid
			}
			guard minID >= 0, maxID >= 0, minID < maxID else {
				throw CloudProviderError.pageTokenInvalid
			}
			convertedPageToken = PageToken(minID: minID, maxID: maxID)
		} else {
			convertedPageToken = PageToken(minID: 0, maxID: maxPageSize)
		}
		let request = CacheElement.filter(CacheElement.Columns.cacheIndex > convertedPageToken.minID && CacheElement.Columns.cacheIndex <= convertedPageToken.maxID && CacheElement.Columns.folderEnumerationPath == folderPath).order(CacheElement.Columns.name)
		let countRequest = CacheElement.filter(CacheElement.Columns.folderEnumerationPath == folderPath)

		let (elements, hasMore) = try dbWriter.read { db -> ([CacheElement], Bool) in
			let elements = try request.fetchAll(db)
			let count = try countRequest.fetchCount(db)
			if count <= convertedPageToken.minID, pageToken != nil {
				throw CloudProviderError.pageTokenInvalid
			}
			let hasMore = count > convertedPageToken.maxID
			return (elements, hasMore)
		}
		var nextPageToken: String?
		if hasMore {
			nextPageToken = "\(convertedPageToken.maxID):\(convertedPageToken.maxID + maxPageSize)"
		}
		let cloudItemMetadata = elements.map { CloudItemMetadata(cachedElement: $0) }
		return DirectoryContentCacheResponse(elements: cloudItemMetadata, nextPageToken: nextPageToken)
	}

	private struct PageToken {
		let minID: Int
		let maxID: Int
	}

	fileprivate struct CacheElement: Codable {
		var id: Int64?
		var cacheIndex: Int64
		let name: String
		var cloudPath: CloudPath {
			return folderEnumerationPath.appendingPathComponent(name)
		}

		let itemType: CloudItemType
		let lastModified: TimeInterval?
		var lastModifiedDate: Date? {
			guard let timeInterval = lastModified else {
				return nil
			}
			return Date(timeIntervalSinceReferenceDate: timeInterval)
		}

		let size: Int?
		let folderEnumerationPath: CloudPath
	}
}

extension DirectoryContentDBCache.CacheElement: FetchableRecord, PersistableRecord {
	static let databaseTableName = "entries"
	enum Columns: String, ColumnExpression {
		case id, cacheIndex, name, itemType, lastModified, size, folderEnumerationPath
	}
}

private extension CloudItemMetadata {
	init(cachedElement: DirectoryContentDBCache.CacheElement) {
		self.init(name: cachedElement.name, cloudPath: cachedElement.cloudPath, itemType: cachedElement.itemType, lastModifiedDate: cachedElement.lastModifiedDate, size: cachedElement.size)
	}
}
