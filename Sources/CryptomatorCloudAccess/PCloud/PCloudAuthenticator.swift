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
import PCloudSDKSwift
import Promises
import UIKit

public enum PCloudAuthenticatorError: Error {
	case missingWindow
	case userCanceled
}

public class PCloudAuthenticator {
	private let appKey: String

	public init(appKey: String) {
		self.appKey = appKey
	}

	public func authenticate(from viewController: UIViewController) -> Promise<PCloudCredential> {
		let promise: Promise<OAuth.Result>
		if #available(iOS 13, *) {
			guard let window = viewController.view.window else {
				assertionFailure("Cannot present from a view controller that is not part of the view hierarchy.")
				return Promise(PCloudAuthenticatorError.missingWindow)
			}
			promise = OAuth.performAuthorizationFlow(with: window, appKey: appKey)
		} else {
			promise = OAuth.performAuthorizationFlow(with: WebViewControllerPresenterMobile(presentingViewController: viewController), appKey: appKey)
		}
		return promise.then { result in
			return try self.completeAuthorizationFlow(result: result)
		}
	}

	private func completeAuthorizationFlow(result: OAuth.Result) throws -> PCloudCredential {
		switch result {
		case let .success(user):
			return PCloudCredential(user: user)
		case let .failure(error):
			throw error
		case .cancel:
			throw PCloudAuthenticatorError.userCanceled
		}
	}
}

public extension OAuth {
	@available(iOS 13, OSX 10.15, *)
	static func performAuthorizationFlow(with anchor: ASPresentationAnchor, appKey: String) -> Promise<Result> {
		return wrap { completionBlock in
			return OAuth.performAuthorizationFlow(with: anchor, appKey: appKey, completionBlock: completionBlock)
		}
	}

	static func performAuthorizationFlow(with view: OAuthAuthorizationFlowView, appKey: String) -> Promise<Result> {
		return wrap { completionBlock in
			return OAuth.performAuthorizationFlow(with: view, appKey: appKey, completionBlock: completionBlock)
		}
	}
}
