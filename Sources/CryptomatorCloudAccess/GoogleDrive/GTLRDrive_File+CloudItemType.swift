//
//  GTLRDrive_File+CloudItemType.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 09.07.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

@preconcurrency import GoogleAPIClientForREST_Drive

extension GTLRDrive_File {
	func getCloudItemType() -> CloudItemType {
		guard let mimeType else {
			return .unknown
		}
		return mimeType.convertGoogleDriveMimeTypeToCloudItemType()
	}
}

extension String {
	func convertGoogleDriveMimeTypeToCloudItemType() -> CloudItemType {
		switch self {
		case "application/vnd.google-apps.folder":
			return .folder
		case "application/vnd.google-apps.shortcut":
			return .symlink
		default:
			return .file
		}
	}
}
