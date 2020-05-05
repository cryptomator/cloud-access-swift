//
//  CloudProviderMockTests.swift
//  CloudAccessTests
//
//  Created by Sebastian Stenzel on 05.05.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest

class CloudProviderMockTests: XCTestCase {

    func testFetchItemListContainsMasterkey() {
	   let provider = CloudProviderMock()
	   let result = provider.fetchItemList(forFolderAt: URL.init(fileURLWithPath: "pathToVault"), withPageToken: nil)
	   let expectation = XCTestExpectation(description: "fetchItemList")
	   result.then { cloudItemList in
		   XCTAssertTrue(cloudItemList.items.contains(where: {$0.name == "masterkey.cryptomator"}))
	   }.catch { error in
		   XCTFail("Error in promise: \(error)")
	   }.always {
		   expectation.fulfill()
	   }
	   wait(for: [expectation], timeout: 2.0)
   }

}
