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

	 - Parameter remoteURL: Should conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Returns: Promise with the metadata for a file or folder. If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `remoteURL`.
	 */
	func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata>

	/**
	 Starts fetching the contents of a folder. If the result's `CloudItemList` has a `nextPageToken`, call `fetchItemList()` with the returned `nextPageToken` to retrieve more entries.

	 - Parameter remoteURL: Must point to a folder and therefore conform to the following pattern:
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Parameter pageToken: (Optional) The page token returned by your last call to `fetchItemList()`.
	 - Returns: Promise with the item list for a folder (at page token if specified). If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `remoteURL`.
	 */
	func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList>

	/**
	 Download a file.

	 - Parameter remoteURL: Must point to a file and therefore conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	 - Parameter localURL: Must point to a file and therefore conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	 - Precondition: The file exists at the `remoteURL` of the cloud provider.
	 - Postcondition: The file is stored under the `localURL`.
	 - Returns: Promise with the metadata for the downloaded file. If the download fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `remoteURL`.
	 */
	func downloadFile(from remoteURL: URL, to localURL: URL) -> Promise<CloudItemMetadata>

	/**
	 Upload a file.

	 - Parameter localURL: Must point to a file and therefore conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	 - Parameter remoteURL: Must point to a file and therefore conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	 - Parameter isUpdate: If true, overwrite the existing file at the `remoteURL`.
	 - Precondition: The file to be uploaded exists at the `localURL`.
	 - Postcondition: The file is stored under the `remoteURL` of the cloud provider.
	 - Returns: Promise with the metadata of the uploaded file. If the upload fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if file does not exist at the `localURL`.
	   - `CloudProviderError.itemAlreadyExists` if file already exists at the `remoteURL` and `!isUpdate`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `remoteURL` does not exist.
	 */
	func uploadFile(from localURL: URL, to remoteURL: URL, isUpdate: Bool) -> Promise<CloudItemMetadata>

	/**
	 Create a folder.

	 - Parameter remoteURL: Must point to a folder and therefore conform to the following pattern:
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Returns: Empty promise. If the folder creation fails, promise is rejected with:
	   - `CloudProviderError.itemAlreadyExists` if the folder already exists at the `remoteURL`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `remoteURL` does not exist.
	 */
	func createFolder(at remoteURL: URL) -> Promise<Void>

	/**
	 Delete a file or folder.

	 - Parameter remoteURL: `remoteURL` conforms to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 */
	func deleteItem(at remoteURL: URL) -> Promise<Void>

	/**
	 Move a file or folder to a different location.

	 - Parameter oldRemoteURL: Should conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Parameter newRemoteURL: Should conform to the following pattern:
	   - file: has no slash at the end (e.g. `/folder/example.txt`)
	   - folder: has a slash at the end (e.g. `/folder/subfolder/`)
	 - Precondition: `oldRemoteURL` and `newRemoteURL` point to the same item type (both point to a folder or both point to a file).
	 - Returns: Empty promise. If the move fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `oldRemoteURL`.
	   - `CloudProviderError.itemAlreadyExists` if file already exists at the `newRemoteURL`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `newRemoteURL` does not exist.
	 */
	func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void>
}
