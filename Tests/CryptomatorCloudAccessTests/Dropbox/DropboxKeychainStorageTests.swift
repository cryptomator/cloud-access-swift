//
//  DropboxKeychainStorageTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import SwiftyDropbox
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class DropboxKeychainStorageTests: XCTestCase {
	/// Archived by the ObjC Dropbox SDK 7.2.0 from `DBAccessToken(accessToken: "sl.short-lived-access-token", uid: "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc", refreshToken: "refresh-token", tokenExpirationTimestamp: 1_760_000_000)`
	private let shortLivedArchive = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGmCwwXGBkaVSRudWxs1Q0ODxAREhMUFRZccmVmcmVzaFRva2VuU3VpZFthY2Nlc3NUb2tlbl8QGHRva2VuRXhwaXJhdGlvblRpbWVzdGFtcFYkY2xhc3OABIACgAMjQdo53gAAAACABV8QKGRiaWQ6QUFINGY5OVQwdGFPTkliLU91cld4Yk5RNnl3R1JvcFFuZ2NfEBtzbC5zaG9ydC1saXZlZC1hY2Nlc3MtdG9rZW5dcmVmcmVzaC10b2tlbtIbHB0eWiRjbGFzc25hbWVYJGNsYXNzZXNdREJBY2Nlc3NUb2tlbqIfIF1EQkFjY2Vzc1Rva2VuWE5TT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFEAUwBaAGAAawB4AHwAiACjAKoArACuALAAuQC7AOYBBAESARcBIgErATkBPAFKAAAAAAAAAgEAAAAAAAAAIQAAAAAAAAAAAAAAAAAAAVM="
	/// Archived by the ObjC Dropbox SDK 7.2.0 from `DBAccessToken(accessToken: "long-lived-access-token", uid: "12345")`
	private let longLivedArchive = "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwXGBlVJG51bGzVDQ4PEBESExQVFlxyZWZyZXNoVG9rZW5TdWlkW2FjY2Vzc1Rva2VuXxAYdG9rZW5FeHBpcmF0aW9uVGltZXN0YW1wViRjbGFzc4AAgAKAAyMAAAAAAAAAAIAEVTEyMzQ1XxAXbG9uZy1saXZlZC1hY2Nlc3MtdG9rZW7SGhscHVokY2xhc3NuYW1lWCRjbGFzc2VzXURCQWNjZXNzVG9rZW6iHh9dREJBY2Nlc3NUb2tlblhOU09iamVjdAAIABEAGgAkACkAMgA3AEkATABRAFMAWQBfAGoAdwB7AIcAogCpAKsArQCvALgAugDAANoA3wDqAPMBAQEEARIAAAAAAAACAQAAAAAAAAAgAAAAAAAAAAAAAAAAAAABGw=="

	func testDecodeShortLivedAccessTokenOfObjCSDK() throws {
		let data = try XCTUnwrap(Data(base64Encoded: shortLivedArchive))
		let accessToken = try XCTUnwrap(DropboxKeychainStorage.decodeAccessToken(from: data, uid: "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc"))
		XCTAssertEqual(DropboxAccessToken(accessToken: "sl.short-lived-access-token", uid: "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc", refreshToken: "refresh-token", tokenExpirationTimestamp: 1_760_000_000), accessToken)
	}

	func testDecodeLongLivedAccessTokenOfObjCSDK() throws {
		let data = try XCTUnwrap(Data(base64Encoded: longLivedArchive))
		let accessToken = try XCTUnwrap(DropboxKeychainStorage.decodeAccessToken(from: data, uid: "12345"))
		XCTAssertEqual(DropboxAccessToken(accessToken: "long-lived-access-token", uid: "12345"), accessToken)
	}

	func testDecodeAccessTokenOfSwiftyDropbox() throws {
		let expectedAccessToken = DropboxAccessToken(accessToken: "access-token", uid: "12345", refreshToken: "refresh-token", tokenExpirationTimestamp: 1_760_000_000)
		let data = try JSONEncoder().encode(expectedAccessToken)
		XCTAssertEqual(expectedAccessToken, DropboxKeychainStorage.decodeAccessToken(from: data, uid: "12345"))
	}

	func testDecodePlainAccessToken() {
		XCTAssertEqual(DropboxAccessToken(accessToken: "access-token", uid: "12345"), DropboxKeychainStorage.decodeAccessToken(from: Data("access-token".utf8), uid: "12345"))
	}
}
