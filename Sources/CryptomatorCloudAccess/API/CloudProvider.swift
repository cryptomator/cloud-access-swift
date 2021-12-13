//
//  CloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public protocol CloudProvider {
	/**
	 Fetches the metadata for a file or folder.

	 - Parameter cloudPath: The cloud path of the file or folder to fetch metadata.
	 - Returns: Promise with the metadata for a file or folder. If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file or folder does not exist at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata>

	/**
	 Starts fetching the contents of a folder.

	 If the result's `CloudItemList` has a `nextPageToken`, call `fetchItemList()` with the returned `nextPageToken` to retrieve more entries.
	 If on the other hand the end of the list is reached, `nextPageToken` will not be set.

	 - Parameter cloudPath: The cloud path of the folder to fetch item list.
	 - Parameter pageToken: (Optional) The page token returned by your last call to `fetchItemList()`.
	 - Returns: Promise with the item list for a folder (at page token if specified). If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at `cloudPath`.
	   - `CloudProviderError.itemTypeMismatch` if the cloud provider finds a file instead of a folder at `cloudPath`.
	   - `CloudProviderError.pageTokenInvalid` if the `pageToken` is invalid.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList>

	/**
	 Downloads a file.

	 This method supports implicit progress composition.

	 - Parameter cloudPath: The cloud path of the file to download.
	 - Parameter localURL: The local URL of the desired download location.
	 - Precondition: `localURL` must be a file URL.
	 - Postcondition: The file is stored at `localURL`.
	 - Returns: Empty promise. If the download fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at `cloudPath`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `localURL`.
	   - `CloudProviderError.itemTypeMismatch` if the cloud provider finds a folder instead of a file at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void>

	/**
	 Uploads a file.

	 This method supports implicit progress composition.

	 - Parameter localURL: The local URL of the file to upload.
	 - Parameter cloudPath: The cloud path of the desired upload location.
	 - Parameter replaceExisting: If true, overwrite the existing file at `cloudPath`.
	 - Precondition: `localURL` must be a file URL.
	 - Postcondition: The file is stored at `cloudPath`.
	 - Returns: Promise with the metadata of the uploaded file. If the upload fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `localURL`.
	   - `CloudProviderError.itemAlreadyExists` if the file already exists at the `cloudPath` with `!replaceExisting` or the cloud provider finds a folder instead of a file at `cloudPath` with `replaceExisting`.
	   - `CloudProviderError.itemTypeMismatch` if the local file system finds a folder instead of a file at `localURL`.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `cloudPath` does not exist.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata>

	/**
	 Creates a folder.

	 - Parameter cloudPath: The cloud path of the folder to create.
	 - Returns: Empty promise. If the folder creation fails, promise is rejected with:
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at `cloudPath`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `cloudPath` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func createFolder(at cloudPath: CloudPath) -> Promise<Void>

	/**
	 Deletes a file.

	 - Parameter cloudPath: The cloud path of the file to delete.
	 - Returns: Empty promise. If the deletion fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func deleteFile(at cloudPath: CloudPath) -> Promise<Void>

	/**
	 Recursively deletes a folder.

	 - Parameter cloudPath: The cloud path of the folder to delete.
	 - Returns: Empty promise. If the deletion fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func deleteFolder(at cloudPath: CloudPath) -> Promise<Void>

	/**
	 Moves a file to a different location.

	 - Parameter sourceCloudPath: The cloud path of the file to be moved.
	 - Parameter targetCloudPath: The cloud path of the desired destination.
	 - Returns: Empty promise. If the move fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at `sourceCloudPath`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at `targetCloudPath`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `targetCloudPath` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void>

	/**
	 Moves a folder to a different location.

	 - Parameter sourceCloudPath: The cloud path of the folder to be moved.
	 - Parameter targetCloudPath: The cloud path of the desired destination.
	 - Returns: Empty promise. If the move fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at `sourceCloudPath`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at `targetCloudPath`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `targetCloudPath` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void>
}
