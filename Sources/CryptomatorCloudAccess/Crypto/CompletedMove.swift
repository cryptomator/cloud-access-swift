//
//  CompletedMove.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 16.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Runs a move and then the steps that finish its target, also if the move completed with objects remaining at its source.

 - Throws: The error of `finalize`, because a target that isn't finished isn't usable. Otherwise `CloudProviderError.moveCompletedWithSourceRemaining` if the move threw it. Any other error of `move` is thrown at once, without running `finalize`.
 */
func completingMove(_ move: () async throws -> Void, finalize: () async throws -> Void) async throws {
	var isSourceRemaining = false
	do {
		try await move()
	} catch CloudProviderError.moveCompletedWithSourceRemaining {
		isSourceRemaining = true
	}
	try await finalize()
	if isSourceRemaining {
		throw CloudProviderError.moveCompletedWithSourceRemaining
	}
}
