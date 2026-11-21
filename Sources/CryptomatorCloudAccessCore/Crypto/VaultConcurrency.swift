//
//  VaultConcurrency.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 The number of item operations that a vault listing page or a level of a vault folder delete runs at once, e.g., name file downloads, dir file downloads and subfolder listings.

 On HTTP/1.1, URLSession queues the requests beyond its connections per host, and the time a request waits in that queue counts against its timeout. A page of hundreds of items can therefore let queued requests time out.

 Each nested level of a folder delete applies the limit separately, so a deep tree can have more operations in flight.
 */
let vaultItemConcurrencyLimit = 8
