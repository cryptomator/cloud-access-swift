//
//  MicrosoftGraphAPI.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

enum MicrosoftGraphAPI {
	static let host = "graph.microsoft.com"
	static let baseURL = "https://\(host)/v1.0"

	struct DriveItem: Decodable {
		let id: String
		let name: String?
		let size: Int64?
		let folder: Folder?
		let remoteItem: RemoteItem?
		let parentReference: ItemReference?
		let fileSystemInfo: FileSystemInfo?

		var cloudItemType: CloudItemType {
			let folder: Folder? = if let remoteItem {
				remoteItem.folder
			} else {
				self.folder
			}
			return folder != nil ? .folder : .file
		}
	}

	struct RemoteItem: Decodable {
		let id: String?
		let folder: Folder?
		let parentReference: ItemReference?
	}

	struct ItemReference: Codable {
		let id: String?
		let driveId: String?
	}

	struct Folder: Codable {}

	struct FileSystemInfo: Decodable {
		let lastModifiedDateTime: String?

		var lastModifiedDate: Date? {
			return lastModifiedDateTime.flatMap(Date.date(fromISO8601:))
		}
	}

	struct UploadSession: Decodable {
		let uploadUrl: String?
	}

	struct Collection<Element: Decodable>: Decodable {
		// swiftlint:disable:next nesting
		private enum CodingKeys: String, CodingKey {
			case value
			case nextLink = "@odata.nextLink"
		}

		let value: [Element]
		let nextLink: String?
	}

	struct Site: Decodable {
		let id: String
		let displayName: String?
	}

	struct Drive: Decodable {
		let id: String
		let name: String?
	}

	struct DriveItemRequestBody: Encodable {
		// swiftlint:disable:next nesting
		private enum CodingKeys: String, CodingKey {
			case odataType = "@odata.type"
			case name
			case folder
			case parentReference
		}

		let odataType = "#microsoft.graph.driveItem"
		let name: String
		var folder: Folder?
		var parentReference: ItemReference?
	}

	static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		return try JSONDecoder().decode(type, from: data)
	}

	static func encode(_ value: some Encodable) throws -> Data {
		let encoder = JSONEncoder()
		encoder.outputFormatting = .sortedKeys
		return try encoder.encode(value)
	}
}
