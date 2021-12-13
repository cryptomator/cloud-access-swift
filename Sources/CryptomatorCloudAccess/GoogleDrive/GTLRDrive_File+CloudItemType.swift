//
//  GTLRDrive_File+CloudItemType.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 09.07.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import GoogleAPIClientForREST_Drive

extension GTLRDrive_File {
	func getCloudItemType() -> CloudItemType {
		if mimeType == "application/vnd.google-apps.folder" {
			return .folder
		} else {
			return .file
		}
	}
}
