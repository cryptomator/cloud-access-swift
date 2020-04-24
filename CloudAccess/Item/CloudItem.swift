//
//  CloudItem.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 24.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
public protocol CloudItem{
    var localURL: URL { get }
    var metadata: CloudItemMetadata { get }
}
