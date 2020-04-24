//
//  CloudItemList.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
public class CloudItemList {
    public let items: [CloudItemMetadata]
    public let nextPageToken: String?
    
    public init(items: [CloudItemMetadata], nextPageToken: String? = nil) {
        self.items = items
        self.nextPageToken = nextPageToken
    }
}
