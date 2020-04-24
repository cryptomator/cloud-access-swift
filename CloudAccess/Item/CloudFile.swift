//
//  CloudFile.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public class CloudFile {
    
    public let localURL: URL
    public let metadata: CloudItemMetadata
    
    public init(localURL: URL, metadata: CloudItemMetadata) {
        self.localURL = localURL
        self.metadata = metadata
    }
    
}

