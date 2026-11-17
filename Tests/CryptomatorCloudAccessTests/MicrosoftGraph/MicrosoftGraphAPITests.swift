//
//  MicrosoftGraphAPITests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct MicrosoftGraphAPITests {
		@Test
		func decodeDriveItemCollection() throws {
			let json = """
			{
				"value": [
					{"id": "file", "name": "file.txt", "size": 42, "file": {}, "fileSystemInfo": {"lastModifiedDateTime": "2021-04-16T09:30:12.123Z"}},
					{"id": "folder", "name": "folder", "folder": {"childCount": 0}, "fileSystemInfo": {"lastModifiedDateTime": "2021-04-16T09:30:12Z"}},
					{"id": "shortcut", "name": "shared", "remoteItem": {"id": "remote", "folder": {}, "parentReference": {"driveId": "remoteDrive"}}}
				],
				"@odata.nextLink": "https://graph.microsoft.com/v1.0/me/drive/items/root/children?$top=3&$skiptoken=a%3D"
			}
			"""

			let collection = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.Collection<MicrosoftGraphAPI.DriveItem>.self, from: Data(json.utf8))

			#expect(collection.nextLink == "https://graph.microsoft.com/v1.0/me/drive/items/root/children?$top=3&$skiptoken=a%3D")
			let (file, folder, shortcut) = (collection.value[0], collection.value[1], collection.value[2])
			#expect(file.cloudItemType == .file)
			#expect(file.size == 42)
			#expect(try abs(1_618_565_412.123 - #require(file.fileSystemInfo?.lastModifiedDate).timeIntervalSince1970) <= 0.000_1)
			#expect(folder.cloudItemType == .folder)
			#expect(Date(timeIntervalSince1970: 1_618_565_412) == folder.fileSystemInfo?.lastModifiedDate)
			#expect(shortcut.cloudItemType == .folder)
			let shortcutItem = MicrosoftGraphItem(cloudPath: CloudPath("/shared"), driveItem: shortcut)
			#expect(shortcutItem.identifier == "remote")
			#expect(shortcutItem.driveIdentifier == "remoteDrive")
		}

		@Test
		func decodeDownloadURL() throws {
			let json = #"{"id": "file", "name": "file.txt", "size": 42, "file": {}, "@microsoft.graph.downloadUrl": "https://content.example.com/dl/file?tempauth=TOKEN"}"#

			let item = try MicrosoftGraphAPI.decode(MicrosoftGraphAPI.DriveItem.self, from: Data(json.utf8))

			#expect(item.downloadURL == "https://content.example.com/dl/file?tempauth=TOKEN")
			#expect(item.size == 42)
		}
	}
}
