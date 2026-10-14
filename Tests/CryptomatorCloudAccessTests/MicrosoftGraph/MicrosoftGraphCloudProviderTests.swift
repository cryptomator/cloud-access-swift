//
//  MicrosoftGraphCloudProviderTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 26.04.21.
//  Copyright © 2021 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import MSAL
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class MicrosoftGraphCloudProviderTests: XCTestCase {
	var provider: MicrosoftGraphCloudProvider!
	let maxPageSize = 100
	override func setUpWithError() throws {
		let credential = MicrosoftGraphCredential(identifier: "Test", scopes: ["TestScope"], accessTokenProvider: AccessTokenProviderMock(), clientApplication: MSALPublicClientApplication())
		provider = try MicrosoftGraphCloudProvider(credential: credential, maxPageSize: maxPageSize)
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	func testConvertStandardError() {
		let cancellationError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
		XCTAssertTrue(provider.convertStandardError(cancellationError) is CancellationError)
		XCTAssertTrue(provider.convertStandardError(NSError(domain: "Test", code: 0, userInfo: [NSUnderlyingErrorKey: cancellationError])) is CancellationError)
		XCTAssertEqual(.noInternetConnection, provider.convertStandardError(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)) as? CloudProviderError)
	}

	func testChildrenRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.childrenRequest(for: item)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children?$top=100"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testContentRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.contentRequest(for: item)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/content"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testCreateUploadSessionRequest() throws {
		let parentItem = MicrosoftGraphItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let request = try provider.createUploadSessionRequest(for: parentItem, with: "Test.txt")
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier:/Test.txt:/createUploadSession"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testFileChunkUploadRequest() throws {
		let uploadURL = try XCTUnwrap(URL(string: "example.com"))
		let chunkLength = 26
		let totalLength = 128
		let request = provider.fileChunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 0, totalLength: totalLength)
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual("26", request.value(forHTTPHeaderField: "Content-Length"))
		XCTAssertEqual("bytes 0-25/128", request.value(forHTTPHeaderField: "Content-Range"))
		XCTAssertEqual(uploadURL, request.url)
	}

	func testFileChunkUploadRequestWithOffset() throws {
		let uploadURL = try XCTUnwrap(URL(string: "example.com"))
		let chunkLength = 26
		let totalLength = 128
		let request = provider.fileChunkUploadRequest(withUploadURL: uploadURL, chunkLength: chunkLength, offset: 26, totalLength: totalLength)
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual("26", request.value(forHTTPHeaderField: "Content-Length"))
		XCTAssertEqual("bytes 26-51/128", request.value(forHTTPHeaderField: "Content-Range"))
		XCTAssertEqual(uploadURL, request.url)
	}

	func testCreateFolderRequest() throws {
		let parentItem = MicrosoftGraphItem(cloudPath: CloudPath("/testFolder"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .folder)
		let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"folder\":{},\"name\":\"subFolder\"}"
		let request = try provider.createFolderRequest(for: parentItem, with: "subFolder")
		XCTAssertEqual("POST", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier/children"), request.url)
		XCTAssertEqual(expectedRequestBody.data(using: .utf8), request.httpBody)
	}

	func testDeleteItemRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file)
		let request = try provider.deleteItemRequest(for: item)
		XCTAssertEqual("DELETE", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier"), request.url)
		XCTAssertNil(request.httpBody)
	}

	func testMoveItemRequest() throws {
		let item = MicrosoftGraphItem(cloudPath: CloudPath("/test.txt"), identifier: "TestIdentifier", driveIdentifier: nil, itemType: .file)
		let newParentItem = MicrosoftGraphItem(cloudPath: CloudPath("/Folder"), identifier: "TestIdentifier-Folder", driveIdentifier: nil, itemType: .folder)
		let targetCloudPath = CloudPath("/Folder/test.txt")
		let expectedRequestBody = "{\"@odata.type\":\"#microsoft.graph.driveItem\",\"name\":\"test.txt\",\"parentReference\":{\"id\":\"TestIdentifier-Folder\"}}"
		let request = try provider.moveItemRequest(for: item, with: newParentItem, targetCloudPath: targetCloudPath)
		XCTAssertEqual("PATCH", request.httpMethod)
		XCTAssertEqual(URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/TestIdentifier"), request.url)
		XCTAssertEqual(expectedRequestBody.data(using: .utf8), request.httpBody)
	}
}

private final class AccessTokenProviderMock: MicrosoftGraphAccessTokenProvider {
	func getAccessToken() async throws -> String {
		return ""
	}
}
