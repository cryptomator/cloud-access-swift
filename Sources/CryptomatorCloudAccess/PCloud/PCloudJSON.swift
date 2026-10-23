//
//  PCloudJSON.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 19.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The metadata of a file or folder, requested with `timeformat=timestamp`.
struct PCloudMetadata: Decodable, Sendable {
	let isFolder: Bool
	let name: String
	let fileID: UInt64?
	let folderID: UInt64?
	let modified: UInt32
	let size: UInt64?
	/// The children of a listed folder.
	let contents: [PCloudMetadata]?

	var identifier: UInt64? {
		return isFolder ? folderID : fileID
	}

	private enum CodingKeys: String, CodingKey {
		case isFolder = "isfolder"
		case name
		case fileID = "fileid"
		case folderID = "folderid"
		case modified
		case size
		case contents
	}
}

/// A temporary download link of a file. Its path and download tag grant access to the file's content, so neither may be logged.
struct PCloudFileLink: Decodable, Sendable {
	let hosts: [String]
	let path: String
	let dwltag: String
}

enum PCloudJSON {
	/// The codes of a missing, failed or invalid login.
	static let authenticationCodes: Set<Int> = [1000, 2000, 2094]

	/**
	 Returns the body of a successful pCloud result, whose `result` is 0.

	 - Throws: `CloudProviderError.unauthorized` for an authentication code, `PCloudError.apiError` for any other non-zero `result`, and `PCloudError.unexpectedContent` if the body isn't a JSON object with an integer `result`.
	 */
	static func result(of body: Data) throws -> Data {
		let result = try decode(ResultResponse.self, from: body)
		guard result.result != 0 else {
			return body
		}
		if authenticationCodes.contains(result.result) {
			throw CloudProviderError.unauthorized
		}
		throw PCloudError.apiError(code: result.result, message: result.error)
	}

	static func metadata(in body: Data) throws -> PCloudMetadata {
		return try decode(MetadataResponse.self, from: body).metadata
	}

	/// Reads the response of `uploadfile`, which lists the metadata of the uploaded file in an array.
	static func uploadedMetadata(in body: Data) throws -> PCloudMetadata {
		guard let metadata = try decode(UploadResponse.self, from: body).metadata.first else {
			throw PCloudError.unexpectedContent
		}
		return metadata
	}

	static func fileLink(in body: Data) throws -> PCloudFileLink {
		return try decode(PCloudFileLink.self, from: body)
	}

	static func email(in body: Data) throws -> String {
		return try decode(UserInfoResponse.self, from: body).email
	}

	private static func decode<T: Decodable>(_ type: T.Type, from body: Data) throws -> T {
		do {
			return try JSONDecoder().decode(type, from: body)
		} catch {
			throw PCloudError.unexpectedContent
		}
	}

	private struct ResultResponse: Decodable {
		let result: Int
		let error: String?
	}

	private struct MetadataResponse: Decodable {
		let metadata: PCloudMetadata
	}

	private struct UploadResponse: Decodable {
		let metadata: [PCloudMetadata]
	}

	private struct UserInfoResponse: Decodable {
		let email: String
	}
}

/// The login that the pCloud SDK stored: its `OAuth.User` as JSON, with `id`, `token`, `serverRegionId` and `httpAPIHostName`.
enum PCloudLegacyToken {
	private struct StoredUser: Decodable {
		let token: String
		let httpAPIHostName: String
	}

	/**
	 Decodes a token without a refresh token or an expiry, because pCloud tokens never expire.

	 - Throws: `PCloudError.unexpectedContent` if the data isn't such a user or its host isn't a host name of pCloud.
	 */
	static func decode(_ data: Data) throws -> OAuthToken {
		let user: StoredUser
		do {
			user = try JSONDecoder().decode(StoredUser.self, from: data)
		} catch {
			throw PCloudError.unexpectedContent
		}
		guard let apiHost = PCloudCredential.apiHost(user.httpAPIHostName) else {
			throw PCloudError.unexpectedContent
		}
		return OAuthToken(accessToken: user.token, refreshToken: nil, expiresAt: nil, apiHost: apiHost)
	}
}
