//
//  LateMutationCase.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 23.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

enum LateMutationKind: CaseIterable, CustomTestStringConvertible, Sendable {
	case upload
	case createFolder
	case move

	var testDescription: String {
		return "\(self)"
	}
}

/// A mutation of `/new` whose response is processed after another operation moved the new item from `/new` to `/moved`, so that the response names a path the item has left.
struct LateMutationCase: Sendable {
	typealias Response = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)

	private static let target = CloudPath("/new")

	let kind: LateMutationKind
	let localURL: URL
	/// The responses to the requests before the mutation's request.
	let preparation: [Response]
	/// The responses to the requests of the move to `/moved`.
	let renameResponses: [Response]
	/// The responses to the mutation's own requests.
	let mutationResponses: [Response]

	var responses: [Response] {
		return preparation + renameResponses + mutationResponses
	}

	func perform(on provider: any CloudProvider) async throws {
		switch kind {
		case .upload:
			_ = try await provider.uploadFile(from: localURL, to: LateMutationCase.target, replaceExisting: false, progress: nil, onTaskCreation: nil)
		case .createFolder:
			try await provider.createFolder(at: LateMutationCase.target)
		case .move:
			try await provider.moveFile(from: CloudPath("/src"), to: LateMutationCase.target)
		}
	}

	func rename(on provider: any CloudProvider) async throws {
		if kind == .createFolder {
			try await provider.moveFolder(from: LateMutationCase.target, to: CloudPath("/moved"))
		} else {
			try await provider.moveFile(from: LateMutationCase.target, to: CloudPath("/moved"))
		}
	}

	/// Expects the next access to `/new` to look the name up instead of trusting a row. The last scripted response answers that lookup with no item.
	func expectTargetIsLookedUp(on provider: any CloudProvider, requests: RequestRecorder, lookupPath: String, sourceLocation: SourceLocation = #_sourceLocation) async {
		await #expect(throws: CloudProviderError.itemNotFound, sourceLocation: sourceLocation) { try await provider.fetchItemMetadata(at: LateMutationCase.target) }
		#expect(requests.requests.map(\.url?.path) == [lookupPath], sourceLocation: sourceLocation)
		#expect(URLProtocolMock.requestHandler.isEmpty, sourceLocation: sourceLocation)
	}
}
