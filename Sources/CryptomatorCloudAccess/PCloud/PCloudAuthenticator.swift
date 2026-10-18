//
//  PCloudAuthenticator.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 15.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#endif
import AuthenticationServices
@preconcurrency import PCloudSDKSwift
import UIKit

public enum PCloudAuthenticatorError: Error {
	case missingWindow
}

@MainActor
public final class PCloudAuthenticator {
	public static func authenticate(from viewController: UIViewController) async throws -> PCloudCredential {
		guard let window = viewController.view.window else {
			assertionFailure("Cannot present from a view controller that is not part of the view hierarchy.")
			throw PCloudAuthenticatorError.missingWindow
		}
		let result = await OAuth.performAuthorizationFlow(with: window, appKey: PCloudSetup.constants.appKey)
		return try completeAuthorizationFlow(result: result)
	}

	private static func completeAuthorizationFlow(result: OAuth.Result) throws -> PCloudCredential {
		switch result {
		case let .success(user):
			return PCloudCredential(user: user)
		case let .failure(error):
			throw error
		case .cancel:
			throw CocoaError(.userCancelled)
		}
	}
}

@available(iOS 13, OSX 10.15, *)
@MainActor
public extension OAuth {
	static func performAuthorizationFlow(with anchor: ASPresentationAnchor, appKey: String) async -> Result {
		return await withCheckedContinuation { continuation in
			OAuth.performAuthorizationFlow(with: anchor, appKey: appKey, completionBlock: { @Sendable result in
				continuation.resume(returning: result)
			})
		}
	}
}
