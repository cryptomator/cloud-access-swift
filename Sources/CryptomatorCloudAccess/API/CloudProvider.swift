//
//  CloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 A cloud storage service whose files and folders are addressed by cloud paths.

 A provider can be shared between tasks, and its methods don't run on the caller's actor.

 Cancellation is cooperative and has no latency guarantee. Every method checks whether its task is cancelled before it starts and again between its steps, and throws `CancellationError` from the first check that finds the task cancelled. A method that is called from an already cancelled task therefore throws without sending a request, whereas a request or transfer that is already running is not interrupted. Cancellation always surfaces as `CancellationError`, also when the underlying SDK or the system cancelled a request.

 A method doesn't check for cancellation anymore after its commit point:
 - A download commits when it creates the file at the local URL.
 - An upload, a folder creation, a deletion and a move commit with their first remote change after which stopping would break the item, e.g., leave it unreadable or impossible to create again. Without such a change, they commit with their last remote change. From their commit point on, they finish their remaining remote changes even if the task is cancelled.
 - A fetch commits when it returns.

 Remote changes are not rolled back. After a call that threw, a remote item that the call was supposed to create, replace, delete or move may or may not exist. This includes a call that was cancelled, and a call that failed after its commit point because the metadata to return couldn't be read.

 Once a call returned, the provider no longer uses the files of the caller, e.g., the local file of an upload, and it never deletes them.
 */
public protocol CloudProvider: Sendable {
	/**
	 Fetches the metadata for a file or folder.

	 - Parameter cloudPath: The cloud path of the file or folder to fetch metadata.
	 - Returns: The metadata for a file or folder.
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the file or folder does not exist at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata

	/**
	 Starts fetching the contents of a folder.

	 If the result's `CloudItemList` has a `nextPageToken`, call `fetchItemList()` with the returned `nextPageToken` to retrieve more entries.
	 If on the other hand the end of the list is reached, `nextPageToken` will not be set.

	 - Parameter cloudPath: The cloud path of the folder to fetch item list.
	 - Parameter pageToken: (Optional) The page token returned by your last call to `fetchItemList()`.
	 - Returns: The item list for a folder (at page token if specified).
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at `cloudPath`.
	   - `CloudProviderError.itemTypeMismatch` if the cloud provider finds a file instead of a folder at `cloudPath`.
	   - `CloudProviderError.pageTokenInvalid` if the `pageToken` is invalid.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList

	/**
	 Downloads a file.

	 The file is created at `localURL` only after the download and everything that the returned metadata needs succeeded. If this method throws, no item exists at `localURL` unless it existed before.

	 - Parameter cloudPath: The cloud path of the file to download.
	 - Parameter localURL: The local URL of the desired download location.
	 - Parameter progress: (Optional) A fresh `Progress` that the caller owns in order to observe the download. The provider is its exclusive writer and sets its unit counts. It completes only when this method returns, not already when all bytes are transferred. If this method throws, it stays incomplete.
	 - Parameter onTaskCreation: (Optional) Gets called at most once with the suspended `URLSessionDownloadTask`, if the provider downloads the whole file with a single one. The provider awaits the closure before it resumes the task, so the closure must not resume the task. If the calling task is cancelled while the closure runs, the provider never resumes the `URLSessionDownloadTask`.
	 - Precondition: `localURL` must be a file URL.
	 - Postcondition: The file is stored at `localURL`.
	 - Postcondition: The returned metadata has the item type `.file`, and its `size` property is set to the size of the file stored at `localURL`.
	 - Postcondition: The `lastModifiedDate` property of the returned metadata is the date that `fetchItemMetadata(at:)` reports for the file. It is never newer than the downloaded content, but it can be older if the file changes in the cloud during the download.
	 - Returns: The metadata of the downloaded file.
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the file does not exist at `cloudPath`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at the `localURL`.
	   - `CloudProviderError.itemTypeMismatch` if the cloud provider finds a folder instead of a file at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata

	/**
	 Uploads a file.

	 - Parameter localURL: The local URL of the file to upload.
	 - Parameter cloudPath: The cloud path of the desired upload location.
	 - Parameter replaceExisting: If true, overwrite the existing file at `cloudPath`.
	 - Parameter progress: (Optional) A fresh `Progress` that the caller owns in order to observe the upload. The provider is its exclusive writer and sets its unit counts. It completes only when this method returns, not already when all bytes are transferred. If this method throws, it stays incomplete.
	 - Parameter onTaskCreation: (Optional) Gets called at most once with the suspended `URLSessionUploadTask`, if the provider uploads the whole file with a single one. The provider awaits the closure before it resumes the task, so the closure must not resume the task. If the calling task is cancelled while the closure runs, the provider never resumes the `URLSessionUploadTask`, unless the upload passed its commit point before it created the task.
	 - Precondition: `localURL` must be a file URL.
	 - Postcondition: The file is stored at `cloudPath`.
	 - Postcondition: The `size` property of the returned metadata is set to the size of the uploaded file in the cloud and must not be `nil`.
	 - Returns: The metadata of the uploaded file.
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the file does not exist at the `localURL`.
	   - `CloudProviderError.itemAlreadyExists` if the file already exists at the `cloudPath` with `!replaceExisting` or the cloud provider finds a folder instead of a file at `cloudPath` with `replaceExisting`.
	   - `CloudProviderError.itemTypeMismatch` if the local file system finds a folder instead of a file at `localURL`.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `cloudPath` does not exist.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata

	/**
	 Creates a folder.

	 - Parameter cloudPath: The cloud path of the folder to create.
	 - Throws:
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at `cloudPath`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `cloudPath` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func createFolder(at cloudPath: CloudPath) async throws

	/**
	 Deletes a file.

	 - Parameter cloudPath: The cloud path of the file to delete.
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the file does not exist at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func deleteFile(at cloudPath: CloudPath) async throws

	/**
	 Recursively deletes a folder.

	 - Parameter cloudPath: The cloud path of the folder to delete.
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at `cloudPath`.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func deleteFolder(at cloudPath: CloudPath) async throws

	/**
	 Moves a file to a different location.

	 - Parameter sourceCloudPath: The cloud path of the file to be moved.
	 - Parameter targetCloudPath: The cloud path of the desired destination.
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the file does not exist at `sourceCloudPath`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at `targetCloudPath`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `targetCloudPath` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws

	/**
	 Moves a folder to a different location.

	 - Parameter sourceCloudPath: The cloud path of the folder to be moved.
	 - Parameter targetCloudPath: The cloud path of the desired destination.
	 - Throws:
	   - `CloudProviderError.itemNotFound` if the folder does not exist at `sourceCloudPath`.
	   - `CloudProviderError.itemAlreadyExists` if a file or folder already exists at `targetCloudPath`.
	   - `CloudProviderError.parentFolderDoesNotExist` if the parent folder of `targetCloudPath` does not exist.
	   - `CloudProviderError.quotaInsufficient` if the quota of the cloud provider is insufficient to fulfill the request.
	   - `CloudProviderError.unauthorized` if the request lacks valid authentication credentials.
	   - `CloudProviderError.noInternetConnection` if there is no internet connection to handle the request.
	   - `CancellationError` if the task was cancelled, or if the underlying SDK or the system cancelled a request.
	 */
	@concurrent
	func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws
}
