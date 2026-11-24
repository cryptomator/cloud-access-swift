//
//  MicrosoftGraphAPI.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

enum MicrosoftGraphAPI {
	static let host = "graph.microsoft.com"

	/// The address of a drive item in the drive it names, or else in the signed-in user's drive.
	struct ItemAddress {
		let driveIdentifier: String?
		let itemIdentifier: String

		/// The path below the API version.
		var percentEncodedPath: String {
			let item = HTTPClientSupport.pathComponent(itemIdentifier)
			if let driveIdentifier {
				return "/drives/\(HTTPClientSupport.pathComponent(driveIdentifier))/items/\(item)"
			} else {
				return "/me/drive/items/\(item)"
			}
		}
	}

	struct DriveItem: Decodable {
		// swiftlint:disable:next nesting
		private enum CodingKeys: String, CodingKey, CaseIterable {
			case id
			case name
			case size
			case folder
			case fileSystemInfo
			case parentReference
			case remoteItem
			case downloadURL = "@microsoft.graph.downloadUrl"
		}

		/// The value of `$select` that returns every decoded field except the download URL, which Graph leaves out of a `$select` response even when `$select` names it.
		static let selectedFields = CodingKeys.allCases.filter { $0 != .downloadURL }.map(\.stringValue).joined(separator: ",")

		let id: String
		let name: String?
		let size: Int64?
		let folder: Folder?
		let remoteItem: RemoteItem?
		let parentReference: ItemReference?
		let fileSystemInfo: FileSystemInfo?
		/// The pre-authenticated URL of a file's content, which a response carries only without `$select`.
		let downloadURL: String?

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

	/// Parses a URL that a response hands out for requests without the access token, e.g., an upload session's or a file's download URL. Returns `nil` unless it is an HTTPS URL with a host.
	static func preAuthenticatedURL(_ string: String?) -> URL? {
		guard let string, let url = URL(string: string), url.scheme?.lowercased() == "https", url.host(percentEncoded: true)?.isEmpty == false else {
			return nil
		}
		return url
	}

	static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
		return try JSONDecoder().decode(type, from: data)
	}
}
