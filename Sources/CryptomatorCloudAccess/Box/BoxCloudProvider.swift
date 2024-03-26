//
//  BoxCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 19.03.24.
//  Copyright © 2024 Skymatic GmbH. All rights reserved.
//

import BoxSDK
import Foundation
import Promises

public class BoxCloudProvider: CloudProvider {
    private let client: BoxClient
    private let identifierCache: BoxIdentifierCache

    public init(credential: BoxCredential) throws {
        self.client = credential.client
        self.identifierCache = try BoxIdentifierCache()
    }

    public func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
        return resolvePath(forItemAt: cloudPath).then { item in
            self.fetchItemMetadata(for: item)
        }
    }

    public func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList> {
        guard pageToken == nil else {
            return Promise(CloudProviderError.pageTokenInvalid)
        }
        return resolvePath(forItemAt: cloudPath).then { item in
            self.fetchItemList(for: item, pageToken: pageToken)
        }
    }

    public func downloadFile(from cloudPath: CloudPath, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void> {
        precondition(localURL.isFileURL)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return Promise(CloudProviderError.itemAlreadyExists)
        }
        return resolvePath(forItemAt: cloudPath).then { item in
            self.downloadFile(for: item, to: localURL)
        }
    }

    public func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata> {
        precondition(localURL.isFileURL)
        var isDirectory: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDirectory)
        if !fileExists {
            return Promise(CloudProviderError.itemNotFound)
        }
        if isDirectory.boolValue {
            return Promise(CloudProviderError.itemTypeMismatch)
        }
        return fetchItemMetadata(at: cloudPath).then { metadata -> Void in
            if !replaceExisting || (replaceExisting && metadata.itemType == .folder) {
                throw CloudProviderError.itemAlreadyExists
            }
        }.recover { error -> Void in
            guard case CloudProviderError.itemNotFound = error else {
                throw error
            }
        }.then { _ -> Promise<BoxItem> in
            return self.resolveParentPath(forItemAt: cloudPath)
        }.then { parentItem in
            return self.uploadFile(for: parentItem, from: localURL, to: cloudPath)
        }
    }

    public func createFolder(at cloudPath: CloudPath) -> Promise<Void> {
        return checkForItemExistence(at: cloudPath).then { itemExists in
            if itemExists {
                throw CloudProviderError.itemAlreadyExists
            }
        }.then { _ -> Promise<BoxItem> in
            return self.resolveParentPath(forItemAt: cloudPath)
        }.then { parentItem in
            return self.createFolder(for: parentItem, with: cloudPath.lastPathComponent)
        }
    }

    public func deleteFile(at cloudPath: CloudPath) -> Promise<Void> {
        return resolvePath(forItemAt: cloudPath).then { item in
            self.deleteFile(for: item)
        }
    }

    public func deleteFolder(at cloudPath: CloudPath) -> Promise<Void> {
        return resolvePath(forItemAt: cloudPath).then { item in
            self.deleteFolder(for: item)
        }
    }

    public func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
        return checkForItemExistence(at: targetCloudPath).then { itemExists -> Void in
            if itemExists {
                throw CloudProviderError.itemAlreadyExists
            }
        }.then {
           return all(self.resolvePath(forItemAt: sourceCloudPath), self.resolveParentPath(forItemAt: targetCloudPath))
        }.then { item, targetParentItem in
           return self.moveFile(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
        }
    }

    public func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void> {
        return checkForItemExistence(at: targetCloudPath).then { itemExists -> Void in
            if itemExists {
                throw CloudProviderError.itemAlreadyExists
            }
        }.then {
           return all(self.resolvePath(forItemAt: sourceCloudPath), self.resolveParentPath(forItemAt: targetCloudPath))
        }.then { item, targetParentItem in
           return self.moveFolder(from: item, toParent: targetParentItem, targetCloudPath: targetCloudPath)
        }
    }

    // MARK: - Operations

    private func fetchItemMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
        if item.itemType == .file {
            return fetchFileMetadata(for: item)
        } else if item.itemType == .folder {
            return fetchFolderMetadata(for: item)
        } else {
            let error = CloudProviderError.itemTypeMismatch
            CloudAccessDDLogDebug("PCloudCloudProvider: fetchItemMetadata(for: \(item.identifier)) failed with error: \(error)")
            return Promise(error)
        }
    }

    private func fetchFileMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
        assert(item.itemType == .file)
        CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) called")
        return Promise { fulfill, reject in
            self.client.files.get(fileId: item.identifier, fields: ["name", "size", "modified_at"]) { result in
                switch result {
                case let .success(file):
                    do {
                        let metadata = try self.convertToCloudItemMetadata(file, at: item.cloudPath)
                        try self.identifierCache.addOrUpdate(item)
                        CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) successful")
                        fulfill(metadata)
                    } catch {
                        CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) error: \(error)")
                        reject(error)
                    }
                case let .failure(error):
                    CloudAccessDDLogDebug("BoxCloudProvider: fetchFileMetadata(for: \(item.identifier)) failed with error: \(error)")
                    reject(error)
                }
            }
        }
    }

    private func fetchFolderMetadata(for item: BoxItem) -> Promise<CloudItemMetadata> {
        assert(item.itemType == .folder)
        CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) called")
        return Promise { fulfill, reject in
            self.client.folders.get(folderId: item.identifier, fields: ["name", "modified_at"]) { result in
                switch result {
                case let .success(folder):
                    do {
                        let metadata = try self.convertToCloudItemMetadata(folder, at: item.cloudPath)
                        try self.identifierCache.addOrUpdate(item)
                        CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) successful")
                        fulfill(metadata)
                    } catch {
                        CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) error: \(error)")
                        reject(error)
                    }
                case let .failure(error):
                    CloudAccessDDLogDebug("BoxCloudProvider: fetchFolderMetadata(for: \(item.identifier)) failed with error: \(error)")
                    reject(error)
                }
            }
        }
    }

    private func fetchItemList(for item: BoxItem, pageToken: String?) -> Promise<CloudItemList> {
        CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(forFolderAt: \(item.identifier)) called")
        guard item.itemType == .folder else {
            let error = CloudProviderError.itemTypeMismatch
            CloudAccessDDLogDebug("BoxCloudProvider: fetchItemList(forFolderAt: \(item.identifier)) failed with error: \(error)")
            return Promise(error)
        }

        return Promise { fulfill, reject in
            let iterator = self.client.folders.listItems(folderId: item.identifier, usemarker: true, marker: pageToken)
            var allItems: [CloudItemMetadata] = []
            
            iterator.next { result in
                switch result {
                case let .success(page):
                    for folderItem in page.entries {
                        do {
                            let childCloudPath: CloudPath
                            let childItemMetadata: CloudItemMetadata

                            switch folderItem {
                            case let .file(file):
                                childCloudPath = item.cloudPath.appendingPathComponent(file.name ?? "")
                                childItemMetadata = try self.convertToCloudItemMetadata(file, at: childCloudPath)
                            case let .folder(folder):
                                childCloudPath = item.cloudPath.appendingPathComponent(folder.name ?? "")
                                childItemMetadata = try self.convertToCloudItemMetadata(folder, at: childCloudPath)
                            case .webLink:
                                continue
                            }

                            allItems.append(childItemMetadata)

                            let newItem = try BoxItem(cloudPath: childCloudPath, folderItem: folderItem)
                            try self.identifierCache.addOrUpdate(newItem)
                        } catch {
                            reject(error)
                            return
                        }
                    }

                    fulfill(CloudItemList(items: allItems, nextPageToken: page.nextMarker))
                    
                case let .failure(error):
                    reject(error)
                }
            }
        }
    }

    private func downloadFile(for item: BoxItem, to localURL: URL) -> Promise<Void> {
        CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) called")
        return Promise { fulfill, reject in
            let task = self.client.files.download(fileId: item.identifier, destinationURL: localURL) { result in
                switch result {
                case .success:
                    CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) finished downloading")
                    fulfill(())
                case let .failure(error):
                    CloudAccessDDLogDebug("BoxCloudProvider: downloadFile(for: \(item.identifier), to: \(localURL)) failed with error: \(error)")
                    reject(error)
                }
            }
        }
    }

    private func uploadFile(for parentItem: BoxItem, from localURL: URL, to cloudPath: CloudPath) -> Promise<CloudItemMetadata> {
        CloudAccessDDLogDebug("BoxCloudProvider: uploadFile(for: \(parentItem.identifier), from: \(localURL), to: \(cloudPath.path)) called")
        return Promise { fulfill, reject in
            do {
                let fileData = try Data(contentsOf: localURL) //Refactor
                let progress = Progress(totalUnitCount: Int64(fileData.count))
                self.client.files.upload(data: fileData, name: cloudPath.lastPathComponent, parentId: parentItem.identifier, progress: { progressUpdate in
                    print("Upload progress: \(progressUpdate.fractionCompleted)")
                }) { (result: Result<File, BoxSDKError>) in
                    switch result {
                    case let .success(file):
                        CloudAccessDDLogDebug("BoxCloudProvider: uploadFile successful with file ID: \(file.id)")
                        let metadata = CloudItemMetadata(name: file.name ?? "", cloudPath: cloudPath, itemType: .file, lastModifiedDate: file.modifiedAt, size: file.size)
                        do {
                            let boxItem = BoxItem(cloudPath: cloudPath, identifier: file.id, itemType: .file)
                            try self.identifierCache.addOrUpdate(boxItem)
                            fulfill(metadata)
                        } catch {
                            reject(error)
                        }
                    case let .failure(error):
                        CloudAccessDDLogDebug("BoxCloudProvider: uploadFile failed with error: \(error.localizedDescription)")
                        reject(error)
                    }
                }
            } catch {
                reject(error)
            }
        }
    }

    private func createFolder(for parentItem: BoxItem, with name: String) -> Promise<Void> {
        CloudAccessDDLogDebug("BoxCloudProvider: createFolder(for: \(parentItem.identifier), with: \(name)) called")
        return Promise { fulfill, reject in
            let cloudPath = parentItem.cloudPath.appendingPathComponent(name)
            self.resolveParentPath(forItemAt: cloudPath.deletingLastPathComponent()).then { parentItem -> Void in
                self.client.folders.create(name: name, parentId: parentItem.identifier) { result in
                    switch result {
                    case let .success(folder):
                        CloudAccessDDLogDebug("BoxCloudProvider: createFolder successful with folder ID: \(folder.id)")
                        let newItemMetadata = CloudItemMetadata(name: folder.name ?? "", cloudPath: cloudPath.appendingPathComponent(name), itemType: .folder, lastModifiedDate: folder.modifiedAt, size: nil)
                        do {
                            let newItem = BoxItem(cloudPath: cloudPath.appendingPathComponent(name), identifier: folder.id, itemType: .folder)
                            try self.identifierCache.addOrUpdate(newItem)
                            fulfill(())
                        } catch {
                            reject(error)
                        }
                    case let .failure(error):
                        CloudAccessDDLogDebug("BoxCloudProvider: createFolder failed with error: \(error.localizedDescription)")
                        reject(error)
                    }
                }
            }.catch { error in
                reject(error)
            }
        }
    }

    private func deleteFile(for item: BoxItem) -> Promise<Void> {
        CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) called")
        guard item.itemType == .file else {
            return Promise(CloudProviderError.itemTypeMismatch)
        }
        return Promise<Void> { fulfill, reject in
            self.client.files.delete(fileId: item.identifier) { result in
                switch result {
                case .success:
                    CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) succeeded")
                    do {
                        try self.identifierCache.invalidate(item)
                        fulfill(())
                    } catch {
                        CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
                        reject(error)
                    }
                case let .failure(error):
                    CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error)")
                    if case BoxSDKErrorEnum.notFound = error.message {
                        reject(CloudProviderError.itemNotFound)
                    } else {
                        reject(error)
                    }
                }
            }
        }
    }

    private func deleteFolder(for item: BoxItem) -> Promise<Void> {
        CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) called")
        guard item.itemType == .folder else {
            return Promise(CloudProviderError.itemTypeMismatch)
        }
        return Promise<Void> { fulfill, reject in
            self.client.folders.delete(folderId: item.identifier) { result in
                switch result {
                case .success:
                    CloudAccessDDLogDebug("BoxCloudProvider: deleteFile(for: \(item.identifier)) succeeded")
                    do {
                        try self.identifierCache.invalidate(item)
                        fulfill(())
                    } catch {
                        CloudAccessDDLogDebug("BoxCloudProvider: Cache update failed with error: \(error)")
                        reject(error)
                    }
                case let .failure(error):
                    CloudAccessDDLogDebug("BoxCloudProvider: deleteFolder(for: \(item.identifier)) failed with error: \(error)")
                    if case BoxSDKErrorEnum.notFound = error.message {
                        reject(CloudProviderError.itemNotFound)
                    } else {
                        reject(error)
                    }
                }
            }
        }
    }

    private func moveFile(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
        CloudAccessDDLogDebug("BoxCloudProvider: moveFile(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")

        return Promise<Void> { fulfill, reject in
            let newName = targetCloudPath.lastPathComponent
            self.client.files.update(fileId: sourceItem.identifier, name: newName, parentId: targetParentItem.identifier) { result in
                switch result {
                case .success:
                    CloudAccessDDLogDebug("BoxCloudProvider: moveFile succeeded for \(sourceItem.identifier) to \(targetCloudPath.path)")
                    do {
                        try self.identifierCache.invalidate(sourceItem)
                        let newItem = BoxItem(cloudPath: targetCloudPath, identifier: sourceItem.identifier, itemType: sourceItem.itemType)
                        try self.identifierCache.addOrUpdate(newItem)
                        fulfill(())
                    } catch {
                        reject(error)
                    }
                case let .failure(error):
                    CloudAccessDDLogDebug("BoxCloudProvider: moveFile failed for \(sourceItem.identifier) with error: \(error)")
                    reject(error)
                }
            }
        }
    }

    private func moveFolder(from sourceItem: BoxItem, toParent targetParentItem: BoxItem, targetCloudPath: CloudPath) -> Promise<Void> {
        CloudAccessDDLogDebug("BoxCloudProvider: moveFolder(from: \(sourceItem.identifier), toParent: \(targetParentItem.identifier), targetCloudPath: \(targetCloudPath.path)) called")

        return Promise<Void> { fulfill, reject in
            let newName = targetCloudPath.lastPathComponent
            self.client.folders.update(folderId: sourceItem.identifier, name: newName, parentId: targetParentItem.identifier) { result in
                switch result {
                case .success:
                    CloudAccessDDLogDebug("BoxCloudProvider: moveFolder succeeded for \(sourceItem.identifier) to \(targetCloudPath.path)")
                    do {
                        try self.identifierCache.invalidate(sourceItem)
                        let newItem = BoxItem(cloudPath: targetCloudPath, identifier: sourceItem.identifier, itemType: sourceItem.itemType)
                        try self.identifierCache.addOrUpdate(newItem)
                        fulfill(())
                    } catch {
                        reject(error)
                    }
                case let .failure(error):
                    CloudAccessDDLogDebug("BoxCloudProvider: moveFolder failed for \(sourceItem.identifier) with error: \(error)")
                    reject(error)
                }
            }
        }
    }

    // MARK: - Resolve Path

    private func resolvePath(forItemAt cloudPath: CloudPath) -> Promise<BoxItem> {
        var pathToCheckForCache = cloudPath
        var cachedItem = identifierCache.get(pathToCheckForCache)
        while cachedItem == nil, !pathToCheckForCache.pathComponents.isEmpty {
            pathToCheckForCache = pathToCheckForCache.deletingLastPathComponent()
            cachedItem = identifierCache.get(pathToCheckForCache)
        }
        guard let item = cachedItem else {
            return Promise(PCloudError.inconsistentCache)
        }
        if pathToCheckForCache != cloudPath {
            return traverseThroughPath(from: pathToCheckForCache, to: cloudPath, withStartItem: item)
        }
        return Promise(item)
    }

    private func resolveParentPath(forItemAt cloudPath: CloudPath) -> Promise<BoxItem> {
        let parentCloudPath = cloudPath.deletingLastPathComponent()
        return resolvePath(forItemAt: parentCloudPath).recover { error -> BoxItem in
            if case CloudProviderError.itemNotFound = error {
                throw CloudProviderError.parentFolderDoesNotExist
            } else {
                throw error
            }
        }
    }

    private func traverseThroughPath(from startCloudPath: CloudPath, to endCloudPath: CloudPath, withStartItem startItem: BoxItem) -> Promise<BoxItem> {
        assert(startCloudPath.pathComponents.count < endCloudPath.pathComponents.count)
        let startIndex = startCloudPath.pathComponents.count
        let endIndex = endCloudPath.pathComponents.count
        var currentPath = startCloudPath
        var parentItem = startItem
        return Promise(on: .global()) { fulfill, _ in
            for i in startIndex ..< endIndex {
                let itemName = endCloudPath.pathComponents[i]
                currentPath = currentPath.appendingPathComponent(itemName)
                parentItem = try awaitPromise(self.getBoxItem(for: itemName, withParentItem: parentItem))
                try self.identifierCache.addOrUpdate(parentItem)
            }
            fulfill(parentItem)
        }
    }

    func getBoxItem(for name: String, withParentItem parentItem: BoxItem) -> Promise<BoxItem> {
        return Promise { fulfill, reject in
            CloudAccessDDLogDebug("PCloudCloudProvider: getBoxItem(for: \(name), withParentItem: \(parentItem.identifier)) called")

            let iterator = self.client.folders.listItems(folderId: parentItem.identifier)
            iterator.next { result in
                switch result {
                case let .success(page):
                    for item in page.entries {
                        do {
                            if let mappedItem = try self.mapFolderItemToBoxItem(name: name, parentItem: parentItem, item: item) {
                                fulfill(mappedItem)
                                return
                            }
                        } catch {
                            reject(error)
                            return
                        }
                    }
                    reject(CloudProviderError.itemNotFound)
                case let .failure(error):
                    reject(error)
                }
            }
        }
    }

    func mapFolderItemToBoxItem(name: String, parentItem: BoxItem, item: FolderItem) throws -> BoxItem? {
        switch item {
        case let .file(file) where file.name == name:
            return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), file: file)
        case let .folder(folder) where folder.name == name:
            return BoxItem(cloudPath: parentItem.cloudPath.appendingPathComponent(name), folder: folder)
        case .webLink:
            throw PCloudError.unexpectedContent
        default:
            return nil
        }
    }

    // MARK: - Helpers

    private func convertToCloudItemMetadata(_ content: FolderItem, at cloudPath: CloudPath) throws -> CloudItemMetadata {
        switch content {
        case let .file(fileMetadata):
            return try convertToCloudItemMetadata(fileMetadata, at: cloudPath)
        case let .folder(folderMetadata):
            return try convertToCloudItemMetadata(folderMetadata, at: cloudPath)
        default: //Refactor - no default
            throw PCloudError.unexpectedContent
        }
    }

    private func convertToCloudItemMetadata(_ metadata: File, at cloudPath: CloudPath) throws -> CloudItemMetadata {
        let name = metadata.name ?? ""
        let itemType = CloudItemType.file
        let lastModifiedDate = metadata.modifiedAt
        let size = metadata.size
        return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: size)
    }

    private func convertToCloudItemMetadata(_ metadata: Folder, at cloudPath: CloudPath) throws -> CloudItemMetadata {
        let name = metadata.name ?? ""
        let itemType = CloudItemType.folder
        let lastModifiedDate = metadata.modifiedAt
        return CloudItemMetadata(name: name, cloudPath: cloudPath, itemType: itemType, lastModifiedDate: lastModifiedDate, size: nil)
    }

    private func convertToCloudItemList(_ contents: [FolderItem], at cloudPath: CloudPath) throws -> CloudItemList {
        var items = [CloudItemMetadata]()
        for content in contents {
            switch content {
            case let .file(fileMetadata):
                let itemCloudPath = cloudPath.appendingPathComponent(fileMetadata.name ?? "")
                let itemMetadata = try convertToCloudItemMetadata(fileMetadata, at: itemCloudPath)
                items.append(itemMetadata)
            case let .folder(folderMetadata):
                let itemCloudPath = cloudPath.appendingPathComponent(folderMetadata.name ?? "")
                let itemMetadata = try convertToCloudItemMetadata(folderMetadata, at: itemCloudPath)
                items.append(itemMetadata)
            default:
                throw PCloudError.unexpectedContent
            }
        }
        return CloudItemList(items: items, nextPageToken: nil)
    }
}
