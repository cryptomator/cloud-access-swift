//
//  CloudProvider.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public protocol CloudProvider {
	/**
	 Fetches the metadata for a file or folder.

	 - Parameter remoteURL: The remote URL of the file or folder to fetch metadata.
	 - Precondition: `remoteURL` should conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Returns: Promise with the metadata for a file or folder. If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file or folder does not exist at the `remoteURL`.
	 */
	func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata>

	/**
	 Starts fetching the contents of a folder. If the result's `CloudItemList` has a `nextPageToken`, call `fetchItemList()` with the returned `nextPageToken` to retrieve more entries.

	 - Parameter remoteURL: The remote URL of the folder to fetch item list.
	 - Parameter pageToken: (Optional) The page token returned by your last call to `fetchItemList()`.
	 - Precondition: `remoteURL` must point to a folder and therefore conform to the following pattern:
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Returns: Promise with the item list for a folder (at page token if specified). If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at the `remoteURL`.
	 */
	func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList>

	/**
	 Download a file.

	 - Parameter remoteURL: The remote URL of the file to download.
	 - Parameter localURL: The local URL of the desired download location.
	 - Parameter progress: (Optional) A representation of the download progress.
	 - Precondition: `remoteURL` and `localURL` must point to a file and therefore conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	 - Postcondition: The file is stored under the `localURL`.
	 - Returns: Promise with the metadata for the downloaded file. If the download fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `remoteURL`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `localURL`.
	 */
	func downloadFile(from remoteURL: URL, to localURL: URL, progress: Progress?) -> Promise<CloudItemMetadata>

	/**
	 Upload a file.

	 - Parameter localURL: The local URL of the file to upload.
	 - Parameter remoteURL: The remote URL of the desired upload location.
	 - Parameter isUpdate: If true, overwrite the existing file at the `remoteURL`.
	 - Parameter progress: (Optional) A representation of the upload progress.
	 - Precondition: `remoteURL` and `localURL` must point to a file and therefore conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	 - Postcondition: The file is stored under the `remoteURL` of the cloud provider.
	 - Returns: Promise with the metadata of the uploaded file. If the upload fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `localURL`.
	   - `CloudProviderError.itemAlreadyExists` if the file already exists at the `remoteURL` and `!isUpdate`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `remoteURL` does not exist.
	 */
	func uploadFile(from localURL: URL, to remoteURL: URL, isUpdate: Bool, progress: Progress?) -> Promise<CloudItemMetadata>

	/**
	 Create a folder.

	 - Parameter remoteURL: The remote URL of the folder to create.
	 - Precondition: `remoteURL` must point to a folder and therefore conform to the following pattern:
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Returns: Empty promise. If the folder creation fails, promise is rejected with:
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `remoteURL`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `remoteURL` does not exist.
	 */
	func createFolder(at remoteURL: URL) -> Promise<Void>

	/**
	 Delete a file or folder.

	 - Parameter remoteURL: `remoteURL` conforms to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Returns: Empty promise. If the deletion fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if a file or folder does not exist at the `remoteURL`.
	 */
	func deleteItem(at remoteURL: URL) -> Promise<Void>

	/**
	 Move a file or folder to a different location.

	 - Parameter oldRemoteURL: The remote URL of the file or folder to be moved.
	 - Parameter newRemoteURL: The remote URL of the desired destination.
	 - Precondition: `oldRemoteURL` and `newRemoteURL` should conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Precondition: `oldRemoteURL` and `newRemoteURL` point to the same item type (both point to a folder or both point to a file).
	 - Returns: Empty promise. If the move fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file or folder does not exist at the `oldRemoteURL`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `newRemoteURL`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `newRemoteURL` does not exist.
	 */
	func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void>
}
