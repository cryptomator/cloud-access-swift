//
//  IntegrationRunScope.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Foundation
import Testing

/**
 Runs once around the suite: before it, deletes what earlier runs left behind on the selected remote providers, and after it, deletes the run roots of this run.

 Run roots of the current suite are named `iOS-IntegrationTests-<timestamp>-<runID>` and are deleted once older than 24 hours. Roots of the previous suite, `iOS-IntegrationTests-{Plain|VaultFormat6|VaultFormat7}-<runID>`, may still belong to a running hotfix build, so they are only deleted when empty or when their newest file is older than 24 hours.
 */
struct IntegrationRunScope: SuiteTrait, TestScoping {
	private enum LegacyRunRootAge {
		case empty
		case dated(Date)
		case undated
	}

	private static let maximumAge: TimeInterval = 24 * 60 * 60
	/// The depth of the old fixture tree, whose files are at most 3 levels below the root.
	private static let legacyRunRootListingDepth = 3

	var isRecursive: Bool {
		return false
	}

	func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable @concurrent () async throws -> Void) async throws {
		await IntegrationRunScope.sweepLeftovers()
		do {
			try await function()
		} catch {
			await IntegrationFixtures.shared.cleanUp()
			throw error
		}
		await IntegrationFixtures.shared.cleanUp()
	}

	private static func sweepLeftovers() async {
		let kinds = IntegrationProvider.allCases.filter { $0.isRemote && IntegrationBackend.isSelected($0) }
		await withTaskGroup(of: Void.self) { group in
			for kind in kinds {
				group.addTask {
					do {
						try await value(of: Task { try await sweepLeftovers(of: kind) }, timeout: .seconds(300))
					} catch {
						print("[integration-sweep] \(kind.rawValue): \(error)")
					}
				}
			}
		}
	}

	private static func sweepLeftovers(of kind: IntegrationProvider) async throws {
		let provider = try kind.makeProvider()
		let cutoffDate = Date(timeIntervalSinceNow: -maximumAge)
		let rootFolders = try await provider.fetchItemListExhaustively(forFolderAt: CloudPath("/")).items.filter { $0.itemType == .folder }
		for folder in rootFolders {
			if let date = IntegrationFixtures.runRootDate(ofFolderNamed: folder.name) {
				if date < cutoffDate {
					try await delete(folder, with: provider, on: kind)
				}
			} else if folder.name.wholeMatch(of: /iOS-IntegrationTests-(Plain|VaultFormat6|VaultFormat7)-[0-9A-F]{8}/) != nil {
				switch try await age(ofLegacyRunRoot: folder.cloudPath, with: provider) {
				case .empty:
					try await delete(folder, with: provider, on: kind)
				case let .dated(date) where date < cutoffDate:
					try await delete(folder, with: provider, on: kind)
				case .dated:
					continue
				case .undated:
					print("[integration-sweep] \(kind.rawValue): left \(folder.name) in place, because none of its files has a modification date")
				}
			}
		}
	}

	private static func delete(_ folder: CloudItemMetadata, with provider: CloudProvider, on kind: IntegrationProvider) async throws {
		print("[integration-sweep] \(kind.rawValue): deleting \(folder.name)")
		try await provider.deleteFolderIfExisting(at: folder.cloudPath)
	}

	/// Folders are undated on some providers, e.g. Dropbox and S3, so the age is that of the newest file.
	private static func age(ofLegacyRunRoot cloudPath: CloudPath, with provider: CloudProvider) async throws -> LegacyRunRootAge {
		let items = try await provider.fetchItemListExhaustively(forFolderAt: cloudPath).items
		guard !items.isEmpty else {
			return .empty
		}
		guard let date = try await newestFileDate(in: items, with: provider, remainingDepth: legacyRunRootListingDepth - 1) else {
			return .undated
		}
		return .dated(date)
	}

	private static func newestFileDate(in items: [CloudItemMetadata], with provider: CloudProvider, remainingDepth: Int) async throws -> Date? {
		var newestDate = items.filter { $0.itemType == .file }.compactMap(\.lastModifiedDate).max()
		guard remainingDepth > 0 else {
			return newestDate
		}
		for folder in items where folder.itemType == .folder {
			let children = try await provider.fetchItemListExhaustively(forFolderAt: folder.cloudPath).items
			if let date = try await newestFileDate(in: children, with: provider, remainingDepth: remainingDepth - 1) {
				newestDate = max(newestDate ?? date, date)
			}
		}
		return newestDate
	}
}

extension Trait where Self == IntegrationRunScope {
	static var integrationRun: Self {
		return IntegrationRunScope()
	}
}
