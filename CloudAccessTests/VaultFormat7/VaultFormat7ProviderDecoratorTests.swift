//
//  VaultFormat7ProviderDecoratorTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
@testable import CloudAccess

class VaultFormat7ProviderDecoratorTests: XCTestCase {

    override func setUp() {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDown() {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testFetchItemList() {
		let pathToVault = URL(fileURLWithPath: "pathToVault")
		let provider = CloudProviderMock()
		let decorator = VaultFormat7ProviderDecorator(delegate: provider, remotePathToVault: pathToVault)
		// TODO
    }

}
