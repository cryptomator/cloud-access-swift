//
//  OneDriveCloudProviderTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 26.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
import MSAL
import MSGraphClientSDK
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class OneDriveCloudProviderTests: XCTestCase {
	var provider: OneDriveCloudProvider!

	override func setUpWithError() throws {
		let credential = try OneDriveCredential(with: "Test", authProvider: MSAuthenticationProviderMock(), clientApplication: MSALPublicClientApplication())
		provider = try OneDriveCloudProvider(credential: credential, useBackgroundSession: false)
	}

	func testChildrenRequest() throws {
		let item = OneDriveItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.childrenRequest(for: item)
		XCTAssertEqual(HTTPMethodGet, request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children")!, request.url)
		XCTAssertNil(request.httpBody)
	}

	func testContentRequest() throws {
		let item = OneDriveItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.contentRequest(for: item)
		XCTAssertEqual(HTTPMethodGet, request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/content")!, request.url)
		XCTAssertNil(request.httpBody)
	}

	func testCreateUploadSessionRequest() throws {
		let parentItem = OneDriveItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.createUploadSessionRequest(for: parentItem, with: "Test.txt")
		XCTAssertEqual(HTTPMethodPost, request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier:/Test.txt:/createUploadSession")!, request.url)
		XCTAssertNil(request.httpBody)
	}

	func testFileCunkUploadRequest() throws {
		let uploadURL = URL(string: "example.com")!
		let chunkLength = 26
		let totalLength = 128
		let request = provider.fileCunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 0, totalLength: totalLength)
		XCTAssertEqual(HTTPMethodPut, request.httpMethod)
		XCTAssertEqual("26", request.value(forHTTPHeaderField: "Content-Length"))
		XCTAssertEqual("bytes 0-25/128", request.value(forHTTPHeaderField: "Content-Range"))
		XCTAssertEqual(uploadURL, request.url)
	}

	func testFileCunkUploadRequestWithOffset() throws {
		let uploadURL = URL(string: "example.com")!
		let chunkLength = 26
		let totalLength = 128
		let request = provider.fileCunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 26, totalLength: totalLength)
		XCTAssertEqual(HTTPMethodPut, request.httpMethod)
		XCTAssertEqual("26", request.value(forHTTPHeaderField: "Content-Length"))
		XCTAssertEqual("bytes 26-51/128", request.value(forHTTPHeaderField: "Content-Range"))
		XCTAssertEqual(uploadURL, request.url)
	}

	func testCreateFolderRequest() throws {
		let parentItem = OneDriveItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"name\":\"subFolder\",\"folder\":{}}"
		let request = try provider.createFolderRequest(for: parentItem, with: "subFolder")
		XCTAssertEqual(HTTPMethodPost, request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children")!, request.url)
		XCTAssertEqual(expectedRequestBody.data(using: .utf8), request.httpBody)
	}

	func testDeleteItemRequest() throws {
		let item = OneDriveItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file)
		let request = try provider.deleteItemRequest(for: item)
		XCTAssertEqual(HTTPMethodDelete, request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier")!, request.url)
		XCTAssertNil(request.httpBody)
	}

	func testMoveItemRequest() throws {
		let item = OneDriveItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file)
		let newParentItem = OneDriveItem(cloudPath: CloudPath("/Folder"), identifier: "TestIdentifier-Folder", driveIdentifier: nil, itemType: .folder)
		let targetCloudPath = CloudPath("/Folder/test.txt")
		let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"name\":\"test.txt\",\"parentReference\":{\"id\":\"TestIdentifier-Folder\"}}"
		let request = try provider.moveItemRequest(for: item, with: newParentItem, targetCloudPath: targetCloudPath)
		XCTAssertEqual(HTTPMethodPatch, request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier")!, request.url)
		XCTAssertEqual(expectedRequestBody.data(using: .utf8), request.httpBody)
	}
}

private class MSAuthenticationProviderMock: NSObject, MSAuthenticationProvider {
	func getAccessToken(for authProviderOptions: MSAuthenticationProviderOptions!, andCompletion completion: ((String?, Error?) -> Void)!) {
		completion(nil, nil)
	}
}
