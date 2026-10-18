//
//  IntegrationFixtures.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif
import Foundation

/// The providers of an account and the folder of this run in it, shared by all vault formats.
struct IntegrationAccount: Sendable {
	let kind: IntegrationProvider
	let provider: CloudProvider
	let limitedProvider: CloudProvider
	let runRoot: CloudPath

	func makeTestProvider() throws -> CloudProvider {
		return kind.needsProviderPerTest ? try kind.makeProvider() : provider
	}

	func makeLimitedTestProvider() throws -> CloudProvider {
		return kind.needsProviderPerTest ? try kind.makeProvider(maxPageSize: IntegrationFixtures.maxPageSizeForLimitedProvider) : limitedProvider
	}
}

struct IntegrationVault: Sendable {
	enum Format: Sendable {
		case vf6
		case vf7

		init?(_ format: IntegrationVaultFormat) {
			switch format {
			case .plain:
				return nil
			case .vf6:
				self = .vf6
			case .vf7:
				self = .vf7
			}
		}
	}

	static let password = "IntegrationTest"

	let format: Format
	let path: CloudPath
	let cryptor: VaultCryptor

	static func create(_ format: Format, at path: CloudPath, delegate: CloudProvider, waitUntilVisible: @Sendable (CloudPath) async throws -> Void) async throws -> IntegrationVault {
		let cryptor: VaultCryptor = switch format {
		case .vf6:
			try await DecoratorFactory.createNewVaultFormat6(delegate: delegate, vaultPath: path, password: password, waitUntilVisible: waitUntilVisible).cryptor
		case .vf7:
			try await DecoratorFactory.createNewVaultFormat7(delegate: delegate, vaultPath: path, password: password, waitUntilVisible: waitUntilVisible).cryptor
		}
		return IntegrationVault(format: format, path: path, cryptor: cryptor)
	}

	/// A new decorator with the vault's cryptor, which skips downloading and unlocking the masterkey.
	func makeDecorator(delegate: CloudProvider) throws -> CloudProvider {
		switch format {
		case .vf6:
			return try VaultFormat6ProviderDecorator(delegate: delegate, vaultPath: path, cryptor: cryptor)
		case .vf7:
			return try VaultFormat7ProviderDecorator(delegate: delegate, vaultPath: path, cryptor: cryptor)
		}
	}

	/// A new decorator from the vault's files, unlocked with the password.
	func open(delegate: CloudProvider) async throws -> CloudProvider {
		switch format {
		case .vf6:
			return try await DecoratorFactory.createFromExistingVaultFormat6(delegate: delegate, vaultPath: path, password: IntegrationVault.password)
		case .vf7:
			return try await DecoratorFactory.createFromExistingVaultFormat7(delegate: delegate, vaultPath: path, password: IntegrationVault.password)
		}
	}
}

/**
 The read-only tree of a backend, built once per run:

 ```
 └─ basePath
    ├─ IntegrationTest
    │  ├─ testFolder
    │  │  ├─ EmptySubfolder
    │  │  ├─ test 0.txt … test 4.txt
    │  ├─ test 0.txt … test 4.txt
    └─ sandboxes
 ```

 Tests that change anything work in a folder of their own under `sandboxes`.
 */
struct IntegrationFixture: Sendable {
	static let testContentForFilesInRoot = "testContent"
	static let testContentForFilesInTestFolder = "File inside Folder Content"

	let backend: IntegrationBackend
	let account: IntegrationAccount
	/// The cleartext path of the folder that holds the tree: the base folder of a plain backend, or the root of the vault.
	let basePath: CloudPath
	let vault: IntegrationVault?

	var treeRoot: CloudPath {
		return basePath.appendingPathComponent("IntegrationTest")
	}

	var sandboxesPath: CloudPath {
		return basePath.appendingPathComponent("sandboxes")
	}

	/// A vault backend gets a new decorator, so that each test starts with a cold directory ID cache.
	func makeProvider() throws -> CloudProvider {
		let delegate = try account.makeTestProvider()
		return try vault?.makeDecorator(delegate: delegate) ?? delegate
	}

	func makeLimitedProvider() throws -> CloudProvider {
		let delegate = try account.makeLimitedTestProvider()
		return try vault?.makeDecorator(delegate: delegate) ?? delegate
	}
}

/**
 Builds the fixtures on first use and caches them for the rest of the run.

 A build that failed with a transient error or hung is evicted, so that the next attempt builds it again, a fixture at a new path. Any other failure is cached, so that every test of the backend fails fast with it.
 */
actor IntegrationFixtures {
	private final class TaskCache<Key: Hashable, Value: Sendable> {
		var tasks = [Key: Task<Value, Error>]()
	}

	private struct RunRoot: Sendable {
		let provider: CloudProvider
		let path: CloudPath
	}

	static let shared = IntegrationFixtures()

	private static let runID = String(UUID().uuidString.prefix(8))
	/// Formats the start of the run in the name of the run root, e.g. `20261015T093000Z`.
	private static let runRootDateStyle = Date.ISO8601FormatStyle(dateSeparator: .omitted, timeSeparator: .omitted)
	static let runRootName = "iOS-IntegrationTests-\(Date().formatted(runRootDateStyle))-\(runID)"
	private static let buildTimeout: Duration = .seconds(600)
	/// The budget of each step of a build that holds a permit.
	private static let buildStepBudget: Duration = .seconds(300)
	static let maxPageSizeForLimitedProvider = 3

	private let accounts = TaskCache<IntegrationProvider, IntegrationAccount>()
	private let fixtures = TaskCache<IntegrationBackend, IntegrationFixture>()
	private let unauthorizedProviders = TaskCache<IntegrationProvider, CloudProvider>()
	private var runRoots = [IntegrationProvider: RunRoot]()

	func fixture(for backend: IntegrationBackend) async throws -> IntegrationFixture {
		return try await cachedValue(in: fixtures, for: backend) { try await self.buildFixture(for: backend) }
	}

	func unauthorizedProvider(for kind: IntegrationProvider) async throws -> CloudProvider {
		return try await cachedValue(in: unauthorizedProviders, for: kind) { try await kind.makeUnauthorizedProvider() }
	}

	/// The start of the run that a folder named like `runRootName` belongs to, or `nil` for any other folder.
	static func runRootDate(ofFolderNamed name: String) -> Date? {
		guard let match = name.wholeMatch(of: /iOS-IntegrationTests-(\d{8}T\d{6}Z)-[0-9A-F]{8}/) else {
			return nil
		}
		return try? Date(String(match.1), strategy: runRootDateStyle)
	}

	/// Deletes the run roots that this process created, and the folder of the local file system provider.
	func cleanUp() async {
		let runRoots = runRoots
		await withTaskGroup(of: Void.self) { group in
			for (kind, runRoot) in runRoots {
				group.addTask {
					do {
						try await value(of: Task { try await runRoot.provider.deleteFolderIfExisting(at: runRoot.path) }, timeout: .seconds(300))
					} catch {
						print("[integration-cleanup] \(kind.rawValue): deleting \(runRoot.path.path) failed: \(error)")
					}
				}
			}
		}
		try? FileManager.default.removeItem(at: IntegrationProvider.localFileSystemRootURL)
	}

	// MARK: - Caching

	private func cachedValue<Key: Hashable, Value: Sendable>(in cache: TaskCache<Key, Value>, for key: Key, build: @escaping @Sendable () async throws -> Value) async throws -> Value {
		let task: Task<Value, Error>
		if let cachedTask = cache.tasks[key] {
			task = cachedTask
		} else {
			task = Task { try await build() }
			cache.tasks[key] = task
		}
		do {
			return try await value(of: task, timeout: IntegrationFixtures.buildTimeout)
		} catch let error as UnfinishedTaskError {
			evict(task, for: key, from: cache)
			task.cancel()
			throw IntegrationTestError.fixtureTimeout(error.timeout)
		} catch {
			if IntegrationFixtures.isRetryableBuildFailure(error) {
				evict(task, for: key, from: cache)
			}
			throw error
		}
	}

	/// Whether a build that failed with the error is built again on the next attempt: when the failure was transient, or a step of the build hung.
	static func isRetryableBuildFailure(_ error: Error) -> Bool {
		if case IntegrationTestError.budgetExceeded = error {
			return true
		}
		return isTransientIntegrationError(error)
	}

	private func evict<Key: Hashable, Value: Sendable>(_ task: Task<Value, Error>, for key: Key, from cache: TaskCache<Key, Value>) {
		if cache.tasks[key] == task {
			cache.tasks[key] = nil
		}
	}

	// MARK: - Building

	private func account(for kind: IntegrationProvider) async throws -> IntegrationAccount {
		return try await cachedValue(in: accounts, for: kind) { try await self.buildAccount(for: kind) }
	}

	private func buildAccount(for kind: IntegrationProvider) async throws -> IntegrationAccount {
		let provider = try kind.makeProvider()
		let limitedProvider = try kind.makeProvider(maxPageSize: IntegrationFixtures.maxPageSizeForLimitedProvider)
		let runRoot = CloudPath("/\(IntegrationFixtures.runRootName)")
		runRoots[kind] = RunRoot(provider: provider, path: runRoot)
		try await kind.semaphore.withPermit(budget: IntegrationFixtures.buildStepBudget) { try await provider.createFolderIfMissing(at: runRoot) }
		try await waitUntilVisible(runRoot, through: provider, on: kind)
		return IntegrationAccount(kind: kind, provider: provider, limitedProvider: limitedProvider, runRoot: runRoot)
	}

	private func buildFixture(for backend: IntegrationBackend) async throws -> IntegrationFixture {
		let kind = backend.kind
		let account = try await account(for: kind)
		let provider = account.provider
		let basePath = account.runRoot.appendingPathComponent("\(backend.format.rawValue)-\(UUID().uuidString.prefix(8))")
		let waitUntilVisibleOnAccount: @Sendable (CloudPath) async throws -> Void = { try await waitUntilVisible($0, through: provider, on: kind) }
		let budget = IntegrationFixtures.buildStepBudget
		let fixture: IntegrationFixture
		if let format = IntegrationVault.Format(backend.format) {
			let vault = try await kind.semaphore.withPermit(budget: budget) {
				try await IntegrationVault.create(format, at: basePath, delegate: provider, waitUntilVisible: waitUntilVisibleOnAccount)
			}
			fixture = IntegrationFixture(backend: backend, account: account, basePath: CloudPath("/"), vault: vault)
		} else {
			try await kind.semaphore.withPermit(budget: budget) { try await provider.createFolder(at: basePath) }
			try await waitUntilVisibleOnAccount(basePath)
			fixture = IntegrationFixture(backend: backend, account: account, basePath: basePath, vault: nil)
		}
		if kind == .s3, let vault = fixture.vault {
			try await IntegrationFixtures.waitForVaultReadiness(rawProvider: provider, vaultPath: vault.path)
		}
		try await IntegrationFixtures.createTree(of: fixture)
		return fixture
	}

	private static func createTree(of fixture: IntegrationFixture) async throws {
		let kind = fixture.backend.kind
		let provider = try fixture.makeProvider()
		let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		defer {
			try? FileManager.default.removeItem(at: tmpDirURL)
		}
		let fileInRootURL = tmpDirURL.appendingPathComponent("fileInRoot", isDirectory: false)
		try IntegrationFixture.testContentForFilesInRoot.write(to: fileInRootURL, atomically: true, encoding: .utf8)
		let fileInTestFolderURL = tmpDirURL.appendingPathComponent("fileInTestFolder", isDirectory: false)
		try IntegrationFixture.testContentForFilesInTestFolder.write(to: fileInTestFolderURL, atomically: true, encoding: .utf8)
		let testFolder = fixture.treeRoot.appendingPathComponent("testFolder")
		let levels: [[TreeItem]] = [
			[.folder(fixture.treeRoot), .folder(fixture.sandboxesPath)],
			(0 ..< 5).map { .file(fileInRootURL, fixture.treeRoot.appendingPathComponent("test \($0).txt")) } + [.folder(testFolder)],
			(0 ..< 5).map { .file(fileInTestFolderURL, testFolder.appendingPathComponent("test \($0).txt")) } + [.folder(testFolder.appendingPathComponent("EmptySubfolder"))]
		]
		for level in levels {
			try await withThrowingTaskGroup(of: Void.self) { group in
				for item in level {
					group.addTask {
						try await create(item, with: provider, on: kind)
					}
				}
				try await group.waitForAll()
			}
			for case let .folder(folderPath) in level {
				try await waitUntilVisible(folderPath, through: provider, on: kind)
			}
		}
		if kind.isEventuallyConsistent {
			let expectedItemCount = 6 // 5 files (test 0-4.txt) + 1 folder
			for folderPath in [fixture.treeRoot, testFolder] {
				_ = try await eventually(on: kind) { try await provider.fetchItemListExhaustively(forFolderAt: folderPath).items.count >= expectedItemCount }
			}
		}
	}

	private enum TreeItem: Sendable {
		case folder(CloudPath)
		case file(URL, CloudPath)

		func create(with provider: CloudProvider) async throws {
			switch self {
			case let .folder(cloudPath):
				try await provider.createFolder(at: cloudPath)
			case let .file(localURL, cloudPath):
				_ = try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false)
			}
		}
	}

	/**
	 Creates the item, retrying while it fails because an item it depends on isn't visible yet (e.g. on S3).

	 The retries are paced and limited by `eventually(on:)` while they hold one of the provider's permits, so that waiting for a permit doesn't use up the time for the provider to catch up.

	 A failed attempt can already have created the item, at least in part, e.g. the folder of a vault decorator's `createFolder` without its `dir.c9r`. A later attempt's `itemAlreadyExists` is therefore thrown as `IntegrationTestError.consistencyTimeout`, so that the fixture is built again at a new path. When the retries run out, an eventually consistent provider throws the same error, and any other provider rethrows the last attempt's error, so that a regression fails the fixture.
	 */
	private static func create(_ item: TreeItem, with provider: CloudProvider, on kind: IntegrationProvider) async throws {
		try await kind.semaphore.withPermit(budget: buildStepBudget) {
			var lastError: Error?
			let isCreated = try await eventually(on: kind) {
				do {
					try await item.create(with: provider)
					return true
				} catch CloudProviderError.itemAlreadyExists where lastError != nil {
					throw IntegrationTestError.consistencyTimeout
				} catch {
					guard isEventualConsistencyError(error) else {
						throw error
					}
					lastError = error
					return false
				}
			}
			if !isCreated, let lastError {
				throw lastError
			}
		}
	}

	private static func isEventualConsistencyError(_ error: Error) -> Bool {
		switch error {
		case CloudProviderError.parentFolderDoesNotExist, CloudProviderError.itemNotFound:
			return true
		default:
			return false
		}
	}

	/**
	 Waits for a vault's `d/` directory structure to become visible on S3.

	 Checks `fetchItemMetadata` on `d/` and its first child as well as the listing, because `S3CloudProvider` checks the parent of each write with `fetchItemMetadata`.
	 */
	private static func waitForVaultReadiness(rawProvider: CloudProvider, vaultPath: CloudPath) async throws {
		let dFolderPath = vaultPath.appendingPathComponent("d")
		_ = try await eventually(on: .s3) {
			do {
				let itemList = try await rawProvider.fetchItemList(forFolderAt: dFolderPath, withPageToken: nil)
				guard let firstChild = itemList.items.first else {
					return false
				}
				_ = try await rawProvider.fetchItemMetadata(at: dFolderPath)
				_ = try await rawProvider.fetchItemMetadata(at: firstChild.cloudPath)
				return true
			} catch CloudProviderError.itemNotFound, CloudProviderError.parentFolderDoesNotExist {
				return false
			} catch {
				if isTransientIntegrationError(error) {
					return false
				}
				throw error
			}
		}
	}
}
