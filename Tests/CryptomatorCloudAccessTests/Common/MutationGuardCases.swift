//
//  MutationGuardCases.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

/// A mutation that the shared preflight of an ID-addressed provider refuses before sending its request, with the lookup responses that the preflight consumes.
struct MutationGuardCase: Sendable {
	let name: String
	let responses: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]
	let expected: CloudProviderError
	let operation: @Sendable (any CloudProvider) async throws -> Void
}

enum MutationGuardCases {
	/**
	 The cases in which a mutation sends no request: with an item of the wrong type, with an item that is no folder as a parent, or with the root as its target. A missing source or target parent ends the move after the lookups that found it missing.

	 - Parameter file: The lookup response in the root that finds the file `/file.txt`.
	 - Parameter folder: The lookup response in the root that finds the folder `/folder`.
	 - Parameter missing: The lookup response in the root that finds no item of the name.
	 */
	static func make(localURL: URL, file: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?), folder: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?), missing: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)) -> [MutationGuardCase] {
		return [
			MutationGuardCase(name: "deleteFile of a folder", responses: [folder], expected: .itemTypeMismatch) { try await $0.deleteFile(at: CloudPath("/folder")) },
			MutationGuardCase(name: "deleteFolder of a file", responses: [file], expected: .itemTypeMismatch) { try await $0.deleteFolder(at: CloudPath("/file.txt")) },
			MutationGuardCase(name: "moveFile of a folder", responses: [folder], expected: .itemTypeMismatch) { try await $0.moveFile(from: CloudPath("/folder"), to: CloudPath("/renamed")) },
			MutationGuardCase(name: "moveFolder of a file", responses: [file], expected: .itemTypeMismatch) { try await $0.moveFolder(from: CloudPath("/file.txt"), to: CloudPath("/renamed")) },
			MutationGuardCase(name: "createFolder in a file", responses: [file], expected: .parentFolderDoesNotExist) { try await $0.createFolder(at: CloudPath("/file.txt/sub")) },
			MutationGuardCase(name: "uploadFile into a file", responses: [file], expected: .parentFolderDoesNotExist) { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt/sub"), replaceExisting: false, progress: nil, onTaskCreation: nil) },
			MutationGuardCase(name: "moveFile into a file", responses: [file], expected: .parentFolderDoesNotExist) { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/file.txt/sub")) },
			MutationGuardCase(name: "moveFolder into a file", responses: [file], expected: .parentFolderDoesNotExist) { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/file.txt/sub")) },
			MutationGuardCase(name: "createFolder below a file mid-path", responses: [file], expected: .parentFolderDoesNotExist) { try await $0.createFolder(at: CloudPath("/file.txt/x/new")) },
			MutationGuardCase(name: "missing source onto an existing target", responses: [missing], expected: .itemNotFound) { try await $0.moveFile(from: CloudPath("/missing.txt"), to: CloudPath("/file.txt")) },
			MutationGuardCase(name: "missing source into a missing parent", responses: [missing], expected: .parentFolderDoesNotExist) { try await $0.moveFile(from: CloudPath("/missing.txt"), to: CloudPath("/missing/file.txt")) },
			MutationGuardCase(name: "createFolder at the root", responses: [], expected: .itemAlreadyExists) { try await $0.createFolder(at: .root) },
			MutationGuardCase(name: "uploadFile to the root", responses: [], expected: .itemAlreadyExists) { _ = try await $0.uploadFile(from: localURL, to: .root, replaceExisting: true, progress: nil, onTaskCreation: nil) },
			MutationGuardCase(name: "moveFile to the root", responses: [], expected: .itemAlreadyExists) { try await $0.moveFile(from: CloudPath("/file.txt"), to: .root) },
			MutationGuardCase(name: "moveFolder to the root", responses: [], expected: .itemAlreadyExists) { try await $0.moveFolder(from: CloudPath("/folder"), to: .root) }
		]
	}

	/// Runs each case on a provider of its own and expects its error and every scripted response to be consumed.
	static func expectErrorsConsumingAllResponses(_ cases: [MutationGuardCase], makeProvider: () throws -> any CloudProvider, sourceLocation: SourceLocation = #_sourceLocation) async throws {
		for testCase in cases {
			let provider = try makeProvider()
			URLProtocolMock.requestHandler = testCase.responses

			await #expect(throws: testCase.expected, "\(testCase.name)", sourceLocation: sourceLocation) { try await testCase.operation(provider) }
			#expect(URLProtocolMock.requestHandler.isEmpty, "\(testCase.name)", sourceLocation: sourceLocation)
		}
	}
}
