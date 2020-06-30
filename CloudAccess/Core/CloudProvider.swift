//
//  CloudProvider.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

/**
 Protocol for a cloud provider.

 If your cloud provider requires authentication, see `CloudAuthentication`. In that case, the best practice would be to pass the specific authentication object as a parameter in `init()`.

 The `remoteURL`s of the methods are expected to be file URLs and not the actual `URL` that might be used internally by the cloud provider implementation. Even though the `remoteURL`s are not actual file URLs, it's more convenient to instantiate them with `URL(fileURLWithPath:)`. E.g., you can expect the path `/` to be the root of the cloud provider. The implementation has to consistently resolve the path if needed.
 */
public protocol CloudProvider {
	/**
	 Fetches the metadata for a file or folder.

	 - Parameter remoteURL: The remote URL of the file or folder to fetch metadata.
	 - Precondition: `remoteURL` must be a file URL.
	 - Returns: Promise with the metadata for a file or folder. If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file or folder does not exist at the `remoteURL`.
	   - `CloudProviderError.itemTypeMismatch` if the file or folder does not match the item type specified in `remoteURL`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata>

	/**
	 Starts fetching the contents of a folder.

	 If the result's `CloudItemList` has a `nextPageToken`, call `fetchItemList()` with the returned `nextPageToken` to retrieve more entries.
	 If on the other hand the end of the list is reached, `nextPageToken` will not be set.

	 - Parameter remoteURL: The remote URL of the folder to fetch item list.
	 - Parameter pageToken: (Optional) The page token returned by your last call to `fetchItemList()`.
	 - Precondition: `remoteURL` must be a file URL.
	 - Precondition: `remoteURL` must point to a folder and therefore `hasDirectoryPath` must be `true`.
	 - Returns: Promise with the item list for a folder (at page token if specified). If the fetch fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at the `remoteURL`.
	   - `CloudProviderError.itemTypeMismatch` if the cloud provider finds a file instead of a folder at `remoteURL`.
	   - `CloudProviderError.pageTokenInvalid` if the `pageToken` is invalid.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList>

	/**
	 Downloads a file.

	 This method supports implicit progress composition.

	 - Parameter remoteURL: The remote URL of the file to download.
	 - Parameter localURL: The local URL of the desired download location.
	 - Precondition: `remoteURL` and `localURL` must be a file URL.
	 - Precondition: `remoteURL` and `localURL` must point to a file and therefore `hasDirectoryPath` must be `false` .
	 - Postcondition: The file is stored under the `localURL`.
	 - Returns: Empty promise. If the download fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `remoteURL`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `localURL`.
	   - `CloudProviderError.itemTypeMismatch` if the cloud provider finds a folder instead of a file at `remoteURL`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func downloadFile(from remoteURL: URL, to localURL: URL) -> Promise<Void>

	/**
	 Uploads a file.

	 This method supports implicit progress composition.

	 - Parameter localURL: The local URL of the file to upload.
	 - Parameter remoteURL: The remote URL of the desired upload location.
	 - Parameter replaceExisting: If true, overwrite the existing file at the `remoteURL`.
	 - Precondition: `remoteURL` and `localURL` must be a file URL.
	 - Precondition: `remoteURL` and `localURL` must point to a file and therefore `hasDirectoryPath` must be `false`.
	 - Postcondition: The file is stored under the `remoteURL` of the cloud provider.
	 - Returns: Promise with the metadata of the uploaded file. If the upload fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `localURL`.
	   - `CloudProviderError.itemAlreadyExists` if the file already exists at the `remoteURL` and `!replaceExisting`.
	   - `CloudProviderError.itemTypeMismatch` if the local file system finds a folder instead of a file at `localURL`.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insuffient to fulfill the request.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `remoteURL` does not exist.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func uploadFile(from localURL: URL, to remoteURL: URL, replaceExisting: Bool) -> Promise<CloudItemMetadata>

	/**
	 Creates a folder.

	 - Parameter remoteURL: The remote URL of the folder to create.
	 - Precondition: `remoteURL` must be a file URL.
	 - Precondition: `remoteURL` must point to a folder and therefore `hasDirectoryPath` must be `true`.
	 - Returns: Empty promise. If the folder creation fails, promise is rejected with:
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `remoteURL`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `remoteURL` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insuffient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func createFolder(at remoteURL: URL) -> Promise<Void>

	/**
	 Recursively deletes a file or folder.

	 - Parameter remoteURL: The remote URL of the file or folder to delete.
	 - Precondition: `remoteURL` must be a file URL.
	 - Returns: Empty promise. If the deletion fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if a file or folder does not exist at the `remoteURL`.
	   - `CloudProviderError.itemTypeMismatch` if the file or folder does not match the item type specified in `remoteURL`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func deleteItem(at remoteURL: URL) -> Promise<Void>

	/**
	 Moves a file or folder to a different location.

	 - Parameter oldRemoteURL: The remote URL of the file or folder to be moved.
	 - Parameter newRemoteURL: The remote URL of the desired destination.
	 - Precondition: `oldRemoteURL` and `newRemoteURL` must be a file URL.
	 - Precondition: `oldRemoteURL` and `newRemoteURL` point to the same item type (both point to a folder or both point to a file).
	 - Returns: Empty promise. If the move fails, promise is rejected with:
	   - `CloudProviderError.itemNotFound` if the file or folder does not exist at the `oldRemoteURL`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `newRemoteURL`.
	   - `CloudProviderError.itemTypeMismatch` if the file or folder does not match the item type specified in `oldRemoteURL`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `newRemoteURL` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insuffient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	 */
	func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void>
}
