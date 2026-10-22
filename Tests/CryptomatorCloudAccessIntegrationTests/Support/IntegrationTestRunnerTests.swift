//
//  IntegrationTestRunnerTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

/// Checks the test runner's retry policy, permits and error classification, the run-root naming, and the wiring of the fixtures on the local file system, which needs no network.
extension IntegrationTests {
	struct Runner {
		private static let backend = IntegrationBackend(.localFileSystem, .plain)

		@Test
		func transientErrorIsRetried() async throws {
			let attempts = OSAllocatedUnfairLock(initialState: 0)
			try await withIntegrationFixture(Runner.backend) { _ in
				let attempt = attempts.withLock { attempts in
					attempts += 1
					return attempts
				}
				if attempt == 1 {
					throw URLError(.timedOut)
				}
			}
			#expect(attempts.withLock { $0 } == 2)
		}

		@Test
		func transientErrorIsRetriedTwiceInNewContexts() async throws {
			let tmpDirURLs = OSAllocatedUnfairLock(initialState: [URL]())
			await #expect(throws: URLError(.timedOut)) {
				try await withIntegrationFixture(Runner.backend, budget: .seconds(60), backoffs: [.zero, .zero], semaphore: AsyncSemaphore(permits: 1)) { context in
					tmpDirURLs.withLock { $0.append(context.tmpDirURL) }
					throw URLError(.timedOut)
				}
			}
			let urls = tmpDirURLs.withLock { $0 }
			#expect(urls.count == 3)
			#expect(Set(urls).count == 3)
		}

		@Test
		func cloudProviderErrorIsNotRetried() async throws {
			try await expectNoRetry(of: CloudProviderError.itemNotFound)
		}

		@Test
		func decoratorErrorIsNotRetried() async throws {
			try await expectNoRetry(of: VaultFormatError.encounteredUnrelatedFile)
		}

		@Test
		func eventuallyChecksLocalFileSystemOnce() async throws {
			let checks = OSAllocatedUnfairLock(initialState: 0)
			let result = try await eventually(on: .localFileSystem) {
				checks.withLock { $0 += 1 }
				return false
			}
			#expect(!result)
			#expect(checks.withLock { $0 } == 1)
		}

		@Test
		func budgetAbandonsHangingOperation() async throws {
			let semaphore = AsyncSemaphore(permits: 1)
			let budget: Duration = .seconds(2)
			// The test runs out the budget through `sleep` once the operation hangs, so that the outcome doesn't depend on timing.
			let operationStarted = AsyncSemaphore(permits: 0)
			let budgetRunsOut = AsyncSemaphore(permits: 0)
			let operationMayReturn = AsyncSemaphore(permits: 0)
			let sleep: @Sendable (Duration) async throws -> Void = { _ in
				await budgetRunsOut.acquire()
			}
			let caller = Task {
				try await semaphore.withPermit(budget: budget, sleep: sleep) {
					await operationStarted.release()
					await operationMayReturn.acquire()
				}
			}
			defer {
				Task { await operationMayReturn.release() }
			}
			try await acquire(operationStarted)
			await budgetRunsOut.release()
			await #expect(throws: IntegrationTestError.budgetExceeded(budget)) {
				try await value(of: caller, timeout: testWaitTimeout)
			}
			try await acquire(semaphore)
		}

		@Test
		func callerCancelledWhileWaitingForThePermitDoesNotRunTheOperation() async throws {
			let semaphore = AsyncSemaphore(permits: 1)
			await semaphore.acquire()
			let ran = OSAllocatedUnfairLock(initialState: false)
			let caller = cancelledTask {
				try await semaphore.withPermit(budget: .seconds(60)) {
					ran.withLock { $0 = true }
				}
			}
			await semaphore.release()
			await #expect(throws: CancellationError.self) {
				try await value(of: caller, timeout: testWaitTimeout)
			}
			#expect(!ran.withLock { $0 })
			try await acquire(semaphore)
		}

		@Test
		func cancellingTheCallerCancelsThePermittedOperation() async throws {
			let semaphore = AsyncSemaphore(permits: 1)
			let operationStarted = AsyncSemaphore(permits: 0)
			let caller = Task {
				try await semaphore.withPermit(budget: .seconds(300)) {
					await operationStarted.release()
					try await Task.sleep(for: .seconds(300))
				}
			}
			try await acquire(operationStarted)
			caller.cancel()
			await #expect(throws: CancellationError.self) {
				try await value(of: caller, timeout: testWaitTimeout)
			}
			try await acquire(semaphore)
		}

		// MARK: - Fixtures

		@Test(arguments: [IntegrationVaultFormat.vf6, .vf7])
		func vaultBackendUsesTheDecoratorOfItsFormat(format: IntegrationVaultFormat) async throws {
			let expectedType: CloudProvider.Type = format == .vf6 ? VaultFormat6ProviderDecorator.self : VaultFormat7ProviderDecorator.self
			try await withIntegrationFixture(IntegrationBackend(.localFileSystem, format)) { context in
				let providers = try await [context.provider, context.makeLimitedProvider(), context.openVault()]
				for provider in providers {
					#expect(ObjectIdentifier(type(of: provider)) == ObjectIdentifier(expectedType), "\(type(of: provider))")
				}
			}
		}

		// MARK: - Classification

		@Test
		func hungOrTransientBuildIsBuiltAgain() {
			#expect(IntegrationFixtures.isRetryableBuildFailure(IntegrationTestError.budgetExceeded(.seconds(300))))
			#expect(IntegrationFixtures.isRetryableBuildFailure(URLError(.timedOut)))
			#expect(!IntegrationFixtures.isRetryableBuildFailure(CloudProviderError.unauthorized))
		}

		@Test
		func tokenRequestFailureOfMicrosoftGraphIsTransientOnlyForServerErrors() {
			#expect(isTransientIntegrationError(MicrosoftGraphAccessTokenProviderMockError.tokenRequestFailed(statusCode: 503)))
			#expect(isTransientIntegrationError(MicrosoftGraphAccessTokenProviderMockError.tokenRequestFailed(statusCode: 429)))
			#expect(!isTransientIntegrationError(MicrosoftGraphAccessTokenProviderMockError.tokenRequestFailed(statusCode: 400)))
		}

		@Test
		func serviceErrorsOfProvidersAreTransient() {
			let errors: [Error] = [
				URLError(.networkConnectionLost),
				CloudProviderError.noInternetConnection,
				IntegrationTestError.consistencyTimeout,
				MicrosoftGraphError.unexpectedHTTPStatusCode(code: 502),
				URLSessionError.httpError(nil, statusCode: 503),
				URLSessionError.httpError(URLError(.networkConnectionLost), statusCode: 200),
				DropboxError.apiError(statusCode: 429, summary: "too_many_requests/.."),
				DropboxError.apiError(statusCode: 503, summary: nil),
				DropboxError.apiError(statusCode: 409, summary: "path_write/too_many_write_operations/.."),
				BoxError.apiError(statusCode: 503, code: nil, message: nil),
				BoxError.apiError(statusCode: 408, code: nil, message: nil),
				GoogleDriveError.apiError(statusCode: 503, reason: "backendError", message: nil),
				GoogleDriveError.apiError(statusCode: 429, reason: nil, message: nil),
				GoogleDriveError.apiError(statusCode: 403, reason: "userRateLimitExceeded", message: nil),
				OAuthTokenEndpointError.unsuccessfulResponse(statusCode: 500, error: "internal_failure", errorDescription: nil),
				S3Error(statusCode: 503, code: "SlowDown"),
				S3Error(statusCode: 502),
				PCloudError.unexpectedHTTPStatusCode(code: 503),
				PCloudError.apiError(code: 4000, message: nil),
				PCloudError.apiError(code: 5000, message: nil)
			]
			for error in errors {
				#expect(isTransientIntegrationError(error), "\(error)")
			}
		}

		@Test
		func failuresThatARetryCannotHealAreNotTransient() {
			let errors: [Error] = [
				CloudProviderError.unauthorized,
				CloudProviderError.itemNotFound,
				CancellationError(),
				URLError(.cancelled),
				IntegrationTestError.itemNotVisible(CloudPath("/item")),
				IntegrationTestError.fixtureTimeout(.seconds(600)),
				IntegrationTestError.budgetExceeded(.seconds(300)),
				URLSessionError.httpError(nil, statusCode: 404),
				DropboxError.apiError(statusCode: 409, summary: "path/not_found/.."),
				GoogleDriveError.apiError(statusCode: 404, reason: "notFound", message: nil),
				GoogleDriveError.apiError(statusCode: 403, reason: "insufficientFilePermissions", message: nil),
				OAuthTokenEndpointError.unsuccessfulResponse(statusCode: 400, error: "invalid_request", errorDescription: nil),
				S3Error(statusCode: 404, code: "NoSuchBucket"),
				S3Error(statusCode: 400, code: "InvalidArgument"),
				PCloudError.apiError(code: 2009, message: nil)
			]
			for error in errors {
				#expect(!isTransientIntegrationError(error), "\(error)")
			}
		}

		// MARK: - Run Roots

		@Test
		func runRootNameCarriesTheStartOfTheRun() throws {
			let date = try #require(IntegrationFixtures.runRootDate(ofFolderNamed: IntegrationFixtures.runRootName))
			#expect(abs(date.timeIntervalSinceNow) < 24 * 60 * 60)
			#expect(IntegrationFixtures.runRootDate(ofFolderNamed: "iOS-IntegrationTests-20261015T093000Z-1A2B3C4D") == Date(timeIntervalSince1970: 1_792_056_600))
			#expect(IntegrationFixtures.runRootDate(ofFolderNamed: "iOS-IntegrationTests-Plain-1A2B3C4D") == nil)
		}

		private func expectNoRetry(of error: some Error & Equatable) async throws {
			let attempts = OSAllocatedUnfairLock(initialState: 0)
			await #expect(throws: error) {
				try await withIntegrationFixture(Runner.backend) { _ in
					attempts.withLock { $0 += 1 }
					throw error
				}
			}
			#expect(attempts.withLock { $0 } == 1)
		}

		private func acquire(_ semaphore: AsyncSemaphore) async throws {
			try await value(of: Task { await semaphore.acquire() }, timeout: testWaitTimeout)
		}
	}
}
