//
//  MSGraphDriveItem+CloudItemType.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 29.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

@preconcurrency import MSGraphClientModels

extension MSGraphDriveItem {
	func getCloudItemType() -> CloudItemType {
		let folder: MSGraphFolder? = if let remoteItem {
			remoteItem.folder
		} else {
			self.folder
		}
		if folder != nil {
			return .folder
		} else {
			return .file
		}
	}
}
