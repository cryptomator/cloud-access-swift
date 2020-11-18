//
//  WebDAVClientTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 18.11.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//
import Foundation
import XCTest
@testable import CryptomatorCloudAccess

class WebDAVClientTests: XCTestCase {
	func testSanitizeBaseURLWithMissingTrailingSlash() throws {
		let credential = WebDAVCredential(baseURL: URL(string: "/cloud/remote.php/webdav")!, username: "", password: "", allowedCertificate: nil)
		let delegate = WebDAVClientURLSessionDelegate(credential: credential)
		let configuration = URLSessionConfiguration.default
		let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		let client = WebDAVClient(credential: credential, session: WebDAVSession(urlSession: urlSession, delegate: delegate))
		XCTAssertEqual(URL(string: "/cloud/remote.php/webdav/"), client.baseURL)
	}

	func testSanitizeBaseURLWithTrailingSlash() throws {
		let credential = WebDAVCredential(baseURL: URL(string: "/cloud/remote.php/webdav/")!, username: "", password: "", allowedCertificate: nil)
		let delegate = WebDAVClientURLSessionDelegate(credential: credential)
		let configuration = URLSessionConfiguration.default
		let urlSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		let client = WebDAVClient(credential: credential, session: WebDAVSession(urlSession: urlSession, delegate: delegate))
		XCTAssertEqual(URL(string: "/cloud/remote.php/webdav/"), client.baseURL)
	}
}
