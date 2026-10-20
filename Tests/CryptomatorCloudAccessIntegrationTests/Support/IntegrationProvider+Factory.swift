//
//  IntegrationProvider+Factory.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// The credentials that all tests of a provider share, so that each is authorized once per run.
private enum SharedCredentials {
	static let box = BoxCredentialMock()
	static let dropbox = DropboxCredentialMock()
	static let googleDrive = Result { try GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: "IntegrationTest") }
	// Microsoft Graph doesn't like to get an access token from the refresh token frequently
	static let microsoftGraph = MicrosoftGraphCredentialMock()
	static let pCloud = Result { try PCloudCredential.integrationTest() }
	static let s3 = IntegrationTestSecrets.s3Credential

	static let webDAVClient = WebDAVClient(credential: IntegrationTestSecrets.webDAVCredential)
}

extension IntegrationProvider {
	/// The folder that the local file system provider works in, removed at the end of the run.
	static let localFileSystemRootURL = FileManager.default.temporaryDirectory.appendingPathComponent("iOS-IntegrationTests-\(UUID().uuidString)", isDirectory: true)

	func makeProvider(maxPageSize: Int = .max) throws -> CloudProvider {
		switch self {
		case .box:
			return try BoxCloudProvider(credential: SharedCredentials.box, maxPageSize: maxPageSize)
		case .dropbox:
			return DropboxCloudProvider(credential: SharedCredentials.dropbox, maxPageSize: maxPageSize)
		case .googleDrive:
			return try GoogleDriveCloudProvider(credential: SharedCredentials.googleDrive.get(), maxPageSize: maxPageSize)
		case .microsoftGraph:
			return try MicrosoftGraphCloudProvider(credential: SharedCredentials.microsoftGraph, maxPageSize: maxPageSize)
		case .pCloud:
			return try PCloudCloudProvider(credential: SharedCredentials.pCloud.get())
		case .s3:
			return try S3CloudProvider(credential: SharedCredentials.s3, maxPageSize: maxPageSize)
		case .webDAV:
			return try WebDAVProvider(with: SharedCredentials.webDAVClient, maxPageSize: maxPageSize)
		case .localFileSystem:
			try FileManager.default.createDirectory(at: IntegrationProvider.localFileSystemRootURL, withIntermediateDirectories: true)
			return try LocalFileSystemProvider(rootURL: IntegrationProvider.localFileSystemRootURL, maxPageSize: maxPageSize)
		}
	}

	/// Creates a provider with its own invalid credential, which leaves the shared credential untouched.
	func makeUnauthorizedProvider() async throws -> CloudProvider {
		switch self {
		case .box:
			return try BoxCloudProvider(credential: BoxInvalidCredentialMock())
		case .dropbox:
			let credential = DropboxCredentialMock()
			credential.deauthenticate()
			return DropboxCloudProvider(credential: credential)
		case .googleDrive:
			let credential = try GoogleDriveAuthenticatorMock.generateAuthorizedCredential(withRefreshToken: IntegrationTestSecrets.googleDriveRefreshToken, tokenUID: "IntegrationTest-Unauthorized")
			credential.deauthenticate()
			return try GoogleDriveCloudProvider(credential: credential)
		case .microsoftGraph:
			let credential = MicrosoftGraphCredentialMock()
			try await credential.deauthenticate()
			return try MicrosoftGraphCloudProvider(credential: credential)
		case .pCloud:
			return try PCloudCloudProvider(credential: .integrationTestInvalid())
		case .s3:
			let credential = SharedCredentials.s3
			let invalidCredential = S3Credential(accessKey: credential.accessKey, secretKey: credential.secretKey + "Foo", url: credential.url, bucket: credential.bucket, region: credential.region)
			return try S3CloudProvider(credential: invalidCredential)
		case .webDAV:
			let credential = IntegrationTestSecrets.webDAVCredential
			let invalidCredential = WebDAVCredential(baseURL: credential.baseURL, username: credential.username, password: credential.password + "Foo", allowedCertificate: credential.allowedCertificate)
			return try WebDAVProvider(with: WebDAVClient(credential: invalidCredential))
		case .localFileSystem:
			preconditionFailure("The local file system has no credential")
		}
	}
}
