//
//  MicrosoftGraphAPITests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class MicrosoftGraphAPITests: XCTestCase {
	func testDecodeDriveItemCollection() throws {
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

		XCTAssertEqual("https://graph.microsoft.com/v1.0/me/drive/items/root/children?$top=3&$skiptoken=a%3D", collection.nextLink)
		let (file, folder, shortcut) = (collection.value[0], collection.value[1], collection.value[2])
		XCTAssertEqual(.file, file.cloudItemType)
		XCTAssertEqual(42, file.size)
		XCTAssertEqual(1_618_565_412.123, try XCTUnwrap(file.fileSystemInfo?.lastModifiedDate).timeIntervalSince1970, accuracy: 0.000_1)
		XCTAssertEqual(.folder, folder.cloudItemType)
		XCTAssertEqual(Date(timeIntervalSince1970: 1_618_565_412), folder.fileSystemInfo?.lastModifiedDate)
		XCTAssertEqual(.folder, shortcut.cloudItemType)
		let shortcutItem = MicrosoftGraphItem(cloudPath: CloudPath("/shared"), driveItem: shortcut)
		XCTAssertEqual("remote", shortcutItem.identifier)
		XCTAssertEqual("remoteDrive", shortcutItem.driveIdentifier)
	}
}
