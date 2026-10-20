//
//  PCloudCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The login of a pCloud account. Persist its fields to re-create it later.
public final class PCloudCredential: Sendable {
	private static let hostNameCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")

	public let id: UInt64
	public var userID: String {
		return String(id)
	}

	public let accessToken: String
	/// The host of the account's API, e.g., `api.pcloud.com` in the US or `eapi.pcloud.com` in the EU.
	public let apiHostName: String
	/// The data region of the account: 1 for the US, 2 for the EU.
	public let locationID: UInt

	/// - Throws: `URLError(.badURL)` if `apiHostName` isn't a bare host name, e.g., `api.pcloud.com`.
	public init(id: UInt64, accessToken: String, apiHostName: String, locationID: UInt) throws {
		let apiHostName = apiHostName.lowercased()
		guard PCloudCredential.isValidAPIHostName(apiHostName) else {
			throw URLError(.badURL)
		}
		self.id = id
		self.accessToken = accessToken
		self.apiHostName = apiHostName
		self.locationID = locationID
	}

	public func getUsername() async throws -> String {
		return try await getUsername(client: .foreground(credential: self))
	}

	func getUsername(client: PCloudClient) async throws -> String {
		return try await client.userInfoEmail()
	}

	/// Whether the lowercased host name is bare, i.e., without a path, query, fragment, user info, port or IPv6 literal, so that every request goes to that host. IPv4 literals pass.
	static func isValidAPIHostName(_ hostName: String) -> Bool {
		guard !hostName.isEmpty, hostName.unicodeScalars.allSatisfy(hostNameCharacters.contains), !hostName.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else {
			return false
		}
		var components = URLComponents()
		components.scheme = "https"
		components.host = hostName
		return components.url?.host == hostName
	}
}
