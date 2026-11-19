//
//  CloudItemMetadataTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct CloudItemMetadataTests {
		private static let metadata = CloudItemMetadata(name: "a", cloudPath: CloudPath("/a"), itemType: .file, lastModifiedDate: Date(timeIntervalSinceReferenceDate: 0), size: 1)

		/// A listed alias equals the value that a client rebuilds from its public fields.
		@Test
		func aliasMarkerIsIgnored() {
			let alias = CloudItemMetadata(name: "a", cloudPath: CloudPath("/a"), itemType: .file, lastModifiedDate: Date(timeIntervalSinceReferenceDate: 0), size: 1, isAlias: true)
			#expect(alias == CloudItemMetadataTests.metadata)
		}

		@Test
		func everyPublicFieldIsCompared() {
			let metadata = CloudItemMetadataTests.metadata
			let variants = [
				CloudItemMetadata(name: "b", cloudPath: metadata.cloudPath, itemType: metadata.itemType, lastModifiedDate: metadata.lastModifiedDate, size: metadata.size),
				CloudItemMetadata(name: metadata.name, cloudPath: CloudPath("/b"), itemType: metadata.itemType, lastModifiedDate: metadata.lastModifiedDate, size: metadata.size),
				CloudItemMetadata(name: metadata.name, cloudPath: metadata.cloudPath, itemType: .folder, lastModifiedDate: metadata.lastModifiedDate, size: metadata.size),
				CloudItemMetadata(name: metadata.name, cloudPath: metadata.cloudPath, itemType: metadata.itemType, lastModifiedDate: nil, size: metadata.size),
				CloudItemMetadata(name: metadata.name, cloudPath: metadata.cloudPath, itemType: metadata.itemType, lastModifiedDate: metadata.lastModifiedDate, size: 2)
			]
			for variant in variants {
				#expect(variant != metadata, "\(variant)")
			}
		}
	}
}
