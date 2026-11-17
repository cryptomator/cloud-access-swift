//
//  UnitTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 17.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Testing

/// Every unit suite must be nested in it (`extension UnitTests { … }`), because the suites share process-wide state and must not run in parallel. That state includes the queues of the `URLProtocol` mocks, `LogCapture`, the process's temporary folder and `DropboxAuthenticator.pendingAuthentication`.
@Suite(.serialized)
struct UnitTests {}
