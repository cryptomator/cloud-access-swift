//
//  CloudItemMetadata.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public class CloudItemMetadata {
    public let name: String
    public let size: NSNumber
    public let remoteURL: URL
    public let lastModifiedDate: Date
    public let isFolder: Bool
    
    public init(name: String, size: NSNumber, remoteURL: URL, lastModifiedDate: Date, isFolder: Bool) {
        self.name = name
        self.size = size
        self.remoteURL = remoteURL
        self.lastModifiedDate = lastModifiedDate
        self.isFolder = isFolder
    }
}
