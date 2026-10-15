//
//  DownloadOperation.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

enum DownloadOperation {
	/**
	 Downloads into a staging file and creates the destination only after the transfer and its metadata succeeded.

	 If the download fails or is cancelled, the staging file is deleted and no item is created at `destination`.

	 - Parameter transfer: Writes the downloaded content to the given staging URL, at which no item exists yet, and returns the metadata of the downloaded item.
	 - Returns: The name, cloud path and last modified date that `transfer` returned, along with the size of the downloaded file.
	 - Throws: `CancellationError` if the task was cancelled before the destination is created, and `CloudProviderError.itemAlreadyExists` if an item already exists at `destination` by then.
	 */
	static func download(to destination: URL, transfer: (URL) async throws -> CloudItemMetadata) async throws -> CloudItemMetadata {
		let stagingFile = try StagingFile()
		do {
			let itemMetadata = try await transfer(stagingFile.url)
			let attributes = try FileManager.default.attributesOfItem(atPath: stagingFile.url.path)
			let metadata = CloudItemMetadata(name: itemMetadata.name, cloudPath: itemMetadata.cloudPath, itemType: .file, lastModifiedDate: itemMetadata.lastModifiedDate, size: Int((attributes as NSDictionary).fileSize()))
			try Task.checkCancellation()
			try stagingFile.publish(to: destination)
			return metadata
		} catch {
			stagingFile.delete()
			throw error
		}
	}
}
