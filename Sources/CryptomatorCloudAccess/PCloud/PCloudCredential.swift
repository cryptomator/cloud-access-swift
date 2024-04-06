//
//  PCloudCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import PCloudSDKSwift
import Promises

public class PCloudCredential {
	public let user: OAuth.User
	public var userID: String {
		return String(user.id)
	}

	private let client: PCloudClient

	public init(user: OAuth.User) {
		self.user = user
		self.client = PCloud.createClient(with: user)
	}

	public func getUsername() -> Promise<String> {
		return client.fetchUserInfo().execute().then { metadata in
			return metadata.emailAddress
		}
	}
}

extension PCloud {
	/**
	 Creates a pCloud client with a background `URLSession`.

	 Does not update the `sharedClient` property. You are responsible for storing it and keeping it alive. Use if you want a more direct control over the lifetime of the `PCloudClient` object. Multiple clients can exist simultaneously.

	 - Parameter user: A `OAuth.User` value obtained from the keychain or the OAuth flow.
	 - Parameter sessionIdentifier: The unique identifier for the `URLSessionConfiguration` object.
	 - Parameter sharedContainerIdentifier: To create a URL session for use by an app extension, set this property to a valid identifier for a container shared between the app extension and its containing app.
	 - Returns: An instance of a `PCloudClient` ready to take requests.
	 */
	public static func createBackgroundClient(with user: OAuth.User, sessionIdentifier: String, sharedContainerIdentifier: String? = nil) -> PCloudClient {
		return createBackgroundClient(
			withAccessToken: user.token,
			apiHostName: user.httpAPIHostName,
			sessionIdentifier: sessionIdentifier,
			sharedContainerIdentifier: sharedContainerIdentifier
		)
	}

	private static func createBackgroundClient(withAccessToken accessToken: String, apiHostName: String, sessionIdentifier: String, sharedContainerIdentifier: String?) -> PCloudClient {
		let authenticator = OAuthAccessTokenBasedAuthenticator(accessToken: accessToken)
		let eventHub = URLSessionEventHub()
		let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
		configuration.sharedContainerIdentifier = sharedContainerIdentifier
		let session = URLSession(configuration: configuration, delegate: eventHub, delegateQueue: nil)
		let foregroundSession = URLSession(configuration: .default, delegate: eventHub, delegateQueue: nil)

		// The event hub is expected to be kept in memory by the operation builder blocks.
		let callOperationBuilder = URLSessionBasedNetworkOperationUtilities.createCallOperationBuilder(with: .https, session: foregroundSession, delegate: eventHub)
		let uploadOperationBuilder = URLSessionBasedNetworkOperationUtilities.createUploadOperationBuilder(with: .https, session: session, delegate: eventHub)
		let downloadOperationBuilder = URLSessionBasedNetworkOperationUtilities.createDownloadOperationBuilder(with: session, delegate: eventHub)
		let callTaskBuilder = PCloudAPICallTaskBuilder(hostProvider: apiHostName, authenticator: authenticator, operationBuilder: callOperationBuilder)
		let uploadTaskBuilder = PCloudAPIUploadTaskBuilder(hostProvider: apiHostName, authenticator: authenticator, operationBuilder: uploadOperationBuilder)
		let downloadTaskBuilder = PCloudAPIDownloadTaskBuilder(hostProvider: apiHostName, authenticator: authenticator, operationBuilder: downloadOperationBuilder)
		return PCloudClient(callTaskBuilder: callTaskBuilder, uploadTaskBuilder: uploadTaskBuilder, downloadTaskBuilder: downloadTaskBuilder)
	}
}
