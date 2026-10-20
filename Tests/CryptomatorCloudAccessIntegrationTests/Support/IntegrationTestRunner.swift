//
//  IntegrationTestRunner.swift
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

/// What a test of a backend works with. Each attempt of a test gets a new context.
struct IntegrationTestContext: Sendable {
	let backend: IntegrationBackend
	let provider: CloudProvider
	let treeRoot: CloudPath
	let tmpDirURL: URL
	private let fixture: IntegrationFixture

	init(fixture: IntegrationFixture) throws {
		self.backend = fixture.backend
		self.provider = try fixture.makeProvider()
		self.treeRoot = fixture.treeRoot
		self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		self.fixture = fixture
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	/// Creates an empty folder that only this attempt uses.
	func makeSandbox() async throws -> CloudPath {
		let cloudPath = sandboxPath()
		try await createPrerequisiteFolder(at: cloudPath)
		return cloudPath
	}

	/// Returns a unique path in an existing folder, without creating anything there.
	func sandboxPath() -> CloudPath {
		return fixture.sandboxesPath.appendingPathComponent(UUID().uuidString)
	}

	/// Creates a folder that the operation under test needs, and waits until it is visible. A create isn't retried, because the vault decorator's `createFolder` isn't idempotent.
	func createPrerequisiteFolder(at cloudPath: CloudPath) async throws {
		try await provider.createFolder(at: cloudPath)
		try await waitUntilVisible(cloudPath, through: provider, on: backend.kind)
	}

	/// Uploads a file that the operation under test needs, and waits until it is visible.
	func uploadPrerequisite(_ content: String, to cloudPath: CloudPath) async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try content.write(to: localURL, atomically: true, encoding: .utf8)
		_ = try await provider.uploadFile(from: localURL, to: cloudPath, replaceExisting: false)
		try await waitUntilVisible(cloudPath, through: provider, on: backend.kind)
	}

	/// A provider that lists at most 3 items per page, except on pCloud, which doesn't paginate.
	func makeLimitedProvider() throws -> CloudProvider {
		return try fixture.makeLimitedProvider()
	}

	/// A provider of the vault of a vault backend, opened from the vault's files with its password.
	func openVault() async throws -> CloudProvider {
		let vault = try #require(fixture.vault, "\(backend.token) has no vault")
		return try await vault.open(delegate: fixture.account.makeTestProvider())
	}

	/// A provider with an invalid credential of its own.
	func makeUnauthorizedProvider() async throws -> CloudProvider {
		return try await IntegrationFixtures.shared.unauthorizedProvider(for: backend.kind)
	}
}

private let attemptBudget: Duration = .seconds(300)
private let retryBackoffs: [Duration] = [.seconds(2), .seconds(8)]

/**
 Runs the body of a test with the fixture of the backend.

 An attempt that fails with a transient error, see `isTransientIntegrationError(_:)`, is retried in a new context, at most twice. Any other error fails the test without a retry.

 The body runs while it holds one of the provider's permits, so that the account isn't overloaded. It gets at most 5 minutes from the moment it got the permit. An attempt that takes longer fails with `IntegrationTestError.budgetExceeded` and is left running, because a running request doesn't respond to cancellation.
 */
func withIntegrationFixture(_ backend: IntegrationBackend, _ body: @escaping @Sendable (IntegrationTestContext) async throws -> Void) async throws {
	try await withIntegrationFixture(backend, budget: attemptBudget, backoffs: retryBackoffs, semaphore: backend.kind.semaphore, body)
}

func withIntegrationFixture(_ backend: IntegrationBackend, budget: Duration, backoffs: [Duration], semaphore: AsyncSemaphore, _ body: @escaping @Sendable (IntegrationTestContext) async throws -> Void) async throws {
	try await retryingTransientErrors(of: backend.token, backoffs: backoffs) {
		// The fixture is awaited without a permit, because its build takes permits of the same semaphore.
		let fixture = try await IntegrationFixtures.shared.fixture(for: backend)
		// The context is created with the permit, so that only tests that run hold a provider and a temporary folder.
		try await semaphore.withPermit(budget: budget) {
			let context = try IntegrationTestContext(fixture: fixture)
			defer {
				try? FileManager.default.removeItem(at: context.tmpDirURL)
			}
			try await body(context)
		}
	}
}

/// Runs the body of a test that needs no fixture with the retries, the permit and the budget of `withIntegrationFixture(_:_:)`.
func withIntegrationRetries(on kind: IntegrationProvider, _ body: @escaping @Sendable () async throws -> Void) async throws {
	try await retryingTransientErrors(of: kind.rawValue, backoffs: retryBackoffs) {
		try await kind.semaphore.withPermit(budget: attemptBudget, body)
	}
}

private func retryingTransientErrors(of token: String, backoffs: [Duration], _ attempt: () async throws -> Void) async throws {
	for attemptNumber in 1 ... backoffs.count + 1 {
		do {
			try await attempt()
			return
		} catch {
			guard attemptNumber <= backoffs.count, isTransientIntegrationError(error) else {
				throw error
			}
			print("[integration-retry] \(Test.current?.name ?? "-") \(token) attempt \(attemptNumber): \(error)")
			try await Task.sleep(for: backoffs[attemptNumber - 1])
		}
	}
}
