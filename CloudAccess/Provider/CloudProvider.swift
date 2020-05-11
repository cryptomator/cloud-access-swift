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
    
    //MARK: Fetching
    
    /**
     - Important: remoteURL conforms to the following pattern:
     - file: has no slash at the end (e.g. /folder/example.txt)
     - folder: has a slash at the end (e.g. /folder/subfolder/)
     */
    func fetchItemMetadata(at remoteURL: URL) -> Promise<CloudItemMetadata>
    
    /**
     - Important: remoteURL conforms to the following pattern:
     - file: has no slash at the end (e.g. /folder/example.txt)
     - folder: has a slash at the end (e.g. /folder/subfolder/)
      - Precondition: 'remoteURL' must point to a folder.
     */
    func fetchItemList(forFolderAt remoteURL: URL, withPageToken pageToken: String?) -> Promise<CloudItemList>
    
    //MARK: Download
    
    /**
     - Precondition: The requested file (file.metadata.remoteURL) exists at the cloud provider
     - Postcondition: The requested file is stored under the file.localURL
     
     reject Promise with CloudProviderError.itemNotFound if the file does not exists at the file.metadata.remoteURL
     */
    func downloadFile(_ file: CloudFile) -> Promise<CloudFile>
    
    
    //MARK: Upload
    
    /**
     - Precondition: The file to be uploaded exists in the location file.localURL
     - Postcondition: The local file is stored at the cloud provider under the remote URL (file.metadata.remoteURL).
     
     reject Promise with CloudProviderError.itemAlreadyExists if file already exists at the file.metadata.remoteURL && !isUpdate
    
     reject Promise with CloudProviderError.itemNotFound if file does not exists at the file.metadata.remoteURL && isUpdate
     */
    func uploadFile(_ file: CloudFile, isUpdate: Bool) -> Promise<CloudItemMetadata>
    
    //MARK: Actions
    
    /**
     - Important: remoteURL conforms to the following pattern:
        - file: has no slash at the end (e.g. /folder/example.txt)
        - folder: has a slash at the end (e.g. /folder/subfolder/)
     
     - Precondition: 'remoteURL' must point to a folder.
     - Postcondition: Promise is rejected with:
        - CloudProviderError.itemAlreadyExists if the folder already exists
        - CloudProviderError.parentFolderDoesNotExist if the parentFolder does not exist
     */
    func createFolder(at remoteURL: URL) -> Promise<Void>
    
    /**
     - Important: remoteURL conforms to the following pattern:
     - file: has no slash at the end (e.g. /folder/example.txt)
     - folder: has a slash at the end (e.g. /folder/subfolder/)
     */
    func deleteItem(at remoteURL: URL) -> Promise<Void>
    
    /**
     - Important: remoteURL conforms to the following pattern:
     - file: has no slash at the end (e.g. /folder/example.txt)
     - folder: has a slash at the end (e.g. /folder/subfolder/)
     - Precondition: oldRemoteURL and newRemoteURL point to the same item type (both point to a folder or both point to a file)
     */
    func moveItem(from oldRemoteURL: URL, to newRemoteURL: URL) -> Promise<Void>
    
}
