//
//  FailingChallengeHandler.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
@testable import CryptomatorCloudAccessCore

struct FailingChallengeHandler: SplitURLSession.ChallengeHandler {
	let failure: any Error

	func decision(for challenge: URLAuthenticationChallenge, task: URLSessionTask) -> SplitURLSession.ChallengeDecision {
		return SplitURLSession.ChallengeDecision(disposition: .cancelAuthenticationChallenge, credential: nil, failure: failure)
	}
}
