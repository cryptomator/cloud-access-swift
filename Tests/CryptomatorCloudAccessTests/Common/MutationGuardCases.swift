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

/// A mutation that a provider refuses, with the responses to every request it sends.
struct MutationGuardCase: Sendable {
	/// A mutation of the shared contract, named by its raw value. The root holds the file `/file.txt` and the folder `/folder`.
	enum Kind: String, CaseIterable, Sendable {
		case deleteFileOfFolder = "deleteFile of a folder"
		case deleteFolderOfFile = "deleteFolder of a file"
		case moveFileOfFolder = "moveFile of a folder"
		case moveFolderOfFile = "moveFolder of a file"
		case createFolderInFile = "createFolder in a file"
		case uploadFileIntoFile = "uploadFile into a file"
		case moveFileIntoFile = "moveFile into a file"
		case moveFolderIntoFile = "moveFolder into a file"
		case createFolderBelowFileMidPath = "createFolder below a file mid-path"
		case missingSourceOntoExistingTarget = "missing source onto an existing target"
		case missingSourceIntoMissingParent = "missing source into a missing parent"
		case createFolderAtRoot = "createFolder at the root"
		case uploadFileToRoot = "uploadFile to the root"
		case moveFileToRoot = "moveFile to the root"
		case moveFolderToRoot = "moveFolder to the root"

		var expected: CloudProviderError {
			switch self {
			case .deleteFileOfFolder, .deleteFolderOfFile, .moveFileOfFolder, .moveFolderOfFile:
				return .itemTypeMismatch
			case .createFolderInFile, .uploadFileIntoFile, .moveFileIntoFile, .moveFolderIntoFile, .createFolderBelowFileMidPath, .missingSourceIntoMissingParent:
				return .parentFolderDoesNotExist
			case .missingSourceOntoExistingTarget:
				return .itemNotFound
			case .createFolderAtRoot, .uploadFileToRoot, .moveFileToRoot, .moveFolderToRoot:
				return .itemAlreadyExists
			}
		}

		/// The mutation, which an upload makes from the local file.
		// swiftlint:disable:next cyclomatic_complexity
		func operation(localURL: URL) -> @Sendable (any CloudProvider) async throws -> Void {
			switch self {
			case .deleteFileOfFolder: return { try await $0.deleteFile(at: CloudPath("/folder")) }
			case .deleteFolderOfFile: return { try await $0.deleteFolder(at: CloudPath("/file.txt")) }
			case .moveFileOfFolder: return { try await $0.moveFile(from: CloudPath("/folder"), to: CloudPath("/renamed")) }
			case .moveFolderOfFile: return { try await $0.moveFolder(from: CloudPath("/file.txt"), to: CloudPath("/renamed")) }
			case .createFolderInFile: return { try await $0.createFolder(at: CloudPath("/file.txt/sub")) }
			case .uploadFileIntoFile: return { _ = try await $0.uploadFile(from: localURL, to: CloudPath("/file.txt/sub"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
			case .moveFileIntoFile: return { try await $0.moveFile(from: CloudPath("/file.txt"), to: CloudPath("/file.txt/sub")) }
			case .moveFolderIntoFile: return { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/file.txt/sub")) }
			case .createFolderBelowFileMidPath: return { try await $0.createFolder(at: CloudPath("/file.txt/x/new")) }
			case .missingSourceOntoExistingTarget: return { try await $0.moveFile(from: CloudPath("/missing.txt"), to: CloudPath("/file.txt")) }
			case .missingSourceIntoMissingParent: return { try await $0.moveFile(from: CloudPath("/missing.txt"), to: CloudPath("/missing/file.txt")) }
			case .createFolderAtRoot: return { try await $0.createFolder(at: .root) }
			case .uploadFileToRoot: return { _ = try await $0.uploadFile(from: localURL, to: .root, replaceExisting: true, progress: nil, onTaskCreation: nil) }
			case .moveFileToRoot: return { try await $0.moveFile(from: CloudPath("/file.txt"), to: .root) }
			case .moveFolderToRoot: return { try await $0.moveFolder(from: CloudPath("/folder"), to: .root) }
			}
		}
	}

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
		return make(localURL: localURL) { kind in
			switch kind {
			case .deleteFileOfFolder, .moveFileOfFolder:
				return [folder]
			case .deleteFolderOfFile, .moveFolderOfFile, .createFolderInFile, .uploadFileIntoFile, .moveFileIntoFile, .moveFolderIntoFile, .createFolderBelowFileMidPath:
				return [file]
			case .missingSourceOntoExistingTarget, .missingSourceIntoMissingParent:
				return [missing]
			case .createFolderAtRoot, .uploadFileToRoot, .moveFileToRoot, .moveFolderToRoot:
				return []
			}
		}
	}

	/// The cases of the shared contract, each with the responses that `trace` returns for its requests, leaving out a case for which it returns `nil`.
	static func make(localURL: URL, trace: (MutationGuardCase.Kind) -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]?) -> [MutationGuardCase] {
		return MutationGuardCase.Kind.allCases.compactMap { kind in
			trace(kind).map { MutationGuardCase(name: kind.rawValue, responses: $0, expected: kind.expected, operation: kind.operation(localURL: localURL)) }
		}
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
