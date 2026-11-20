//
//  VaultFormat7ShortenedNameCache.swift
//  CryptomatorCloudAccess
//
//  Created by Sebastian Stenzel on 18.06.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

struct C9SDir {
	let cloudPath: CloudPath
	let originalName: String
}

enum VaultFormat7ShorteningResult {
	/// A path that needs no shortening.
	case unshortened(CloudPath)
	/// The path of a `.c9s` directory itself.
	case c9sDirectory(C9SDir)
	/// The path of an item inside a `.c9s` directory.
	case insideC9S(CloudPath)

	var cloudPath: CloudPath {
		switch self {
		case let .unshortened(cloudPath), let .insideC9S(cloudPath):
			return cloudPath
		case let .c9sDirectory(c9sDir):
			return c9sDir.cloudPath
		}
	}
}

private extension CloudPath {
	func deletingLastPathComponents(_ count: Int) -> CloudPath {
		precondition(count >= 0)
		if count == 0 {
			return self
		} else {
			return deletingLastPathComponents(count - 1).deletingLastPathComponent()
		}
	}

	func replacingPathComponent(at index: Int, with replacement: String) -> CloudPath {
		let components = path.pathSegments()
		precondition(index < components.count)
		let tailSize = components.count - index
		assert(tailSize > 0)
		var tail = Array(components[(components.count - tailSize)...])
		tail[0] = replacement
		let prefix = Array(components[..<(components.count - tailSize)])
		return CloudPath((prefix + tail).joined(separator: "/"))
	}
}

final class VaultFormat7ShortenedNameCache: Sendable {
	private static let c9sSuffix = ".c9s"

	private let threshold: Int
	private let ciphertextNameCompIdx: Int
	private let originalNames = ShortenedNameMap()

	init(vaultPath: CloudPath, threshold: Int) {
		self.threshold = threshold
		self.ciphertextNameCompIdx = vaultPath.pathComponents.count + 3
	}

	/**
	 Applies the `.c9s` shortening defined in vault format 7 (if required).
	 This **does not** persist the original name to `name.c9s`, though.

	 - Parameter originalPath: The unshortened path.
	 - Returns: `.unshortened(originalPath)` if no shortening is required, otherwise the shortened path as `.c9sDirectory` for a `.c9s` itself or `.insideC9S` for an item in one.
	 */
	func getShortenedPath(_ originalPath: CloudPath) -> VaultFormat7ShorteningResult {
		if originalPath.pathComponents.count <= ciphertextNameCompIdx {
			return .unshortened(originalPath)
		}
		let originalName = originalPath.pathComponents[ciphertextNameCompIdx]
		if originalName.count > threshold {
			let shortenedName = deflateName(originalName)
			let shortenedPath = deflatePath(originalPath, with: shortenedName)
			originalNames.record(shortenedName: shortenedName, originalName: originalName)
			if originalPath.pathComponents.count == ciphertextNameCompIdx + 1 {
				return .c9sDirectory(C9SDir(cloudPath: shortenedPath, originalName: originalName))
			} else {
				return .insideC9S(shortenedPath)
			}
		} else {
			return .unshortened(originalPath)
		}
	}

	/**
	 Undos `.c9s` shortening defined in vault format 7 (if required).

	 - Parameter shortenedPath: A potentially shortened path.
	 - Parameter nameC9SLoader: A closure loading the contents of a `name.c9s` file for the corresponding `c9sDirPath`.
	 - Parameter c9sDirPath: The path of a `.c9s` directory, whose original name should be loaded.
	 - Returns: Either `shortenedPath` if no shortening was applied or the original ("inflated") path.
	 - Throws: `VaultFormatError.invalidNameFile` if the `name.c9s` file holds no single path component, a name that isn't longer than the threshold, or a name whose hash isn't the `.c9s` name.
	 */
	func getOriginalPath(_ shortenedPath: CloudPath, nameC9SLoader loadNameC9S: @Sendable (_ c9sDirPath: CloudPath) async throws -> Data) async throws -> CloudPath {
		if shortenedPath.pathComponents.count <= ciphertextNameCompIdx {
			return shortenedPath
		}
		let shortenedName = shortenedPath.pathComponents[ciphertextNameCompIdx]
		if shortenedName.removingASCIISuffix(VaultFormat7ShortenedNameCache.c9sSuffix) != nil {
			let cutOff = shortenedPath.pathComponents.count - ciphertextNameCompIdx - 1
			let c9sDirPath = shortenedPath.deletingLastPathComponents(cutOff)
			// `getShortenedPath` maps the inflated path back to this `.c9s` only if the name is longer than the threshold and hashes to the `.c9s` name.
			let originalName = try await originalNames.originalName(forShortenedName: shortenedName, loadingNameFile: { try await loadNameC9S(c9sDirPath) }, shortening: deflateName, accepting: { $0.count > threshold })
			return inflatePath(shortenedPath, with: originalName)
		} else {
			return shortenedPath
		}
	}

	/// Whether the path is a `.c9s` directory itself, as opposed to an item in one or an unshortened item.
	func isC9SDirectory(_ cloudPath: CloudPath) -> Bool {
		let pathComponents = cloudPath.pathComponents
		return pathComponents.count == ciphertextNameCompIdx + 1 && pathComponents[ciphertextNameCompIdx].removingASCIISuffix(VaultFormat7ShortenedNameCache.c9sSuffix) != nil
	}

	// MARK: - Internal

	private func deflateName(_ originalName: String) -> String {
		return shortenedNameHash(of: originalName, encoding: .base64url) + VaultFormat7ShortenedNameCache.c9sSuffix
	}

	func deflatePath(_ originalPath: CloudPath, with shortenedName: String) -> CloudPath {
		return originalPath.replacingPathComponent(at: ciphertextNameCompIdx, with: shortenedName)
	}

	private func inflatePath(_ shortenedPath: CloudPath, with originalName: String) -> CloudPath {
		return shortenedPath.replacingPathComponent(at: ciphertextNameCompIdx, with: originalName)
	}
}
