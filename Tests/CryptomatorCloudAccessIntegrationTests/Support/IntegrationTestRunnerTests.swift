//
//  IntegrationTestRunnerTests.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import Foundation
import os
@preconcurrency import PCloudSDKSwift
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
		func budgetAbandonsHangingAttempt() async throws {
			let semaphore = AsyncSemaphore(permits: 1)
			let budget: Duration = .seconds(2)
			let started = OSAllocatedUnfairLock(initialState: false)
			let clock = ContinuousClock()
			let start = clock.now
			await #expect(throws: IntegrationTestError.budgetExceeded(budget)) {
				try await withIntegrationFixture(Runner.backend, budget: budget, backoffs: [], semaphore: semaphore) { _ in
					started.withLock { $0 = true }
					await withCheckedContinuation { HangingContinuations.keep($0) }
				}
			}
			#expect(started.withLock { $0 })
			#expect(clock.now - start < budget + .seconds(5))
			try await value(of: _Concurrency.Task { await semaphore.acquire() }, timeout: .seconds(1))
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
				try await value(of: caller, timeout: .seconds(5))
			}
			#expect(!ran.withLock { $0 })
			try await value(of: _Concurrency.Task { await semaphore.acquire() }, timeout: .seconds(1))
		}

		@Test
		func cancellingTheCallerCancelsThePermittedOperation() async throws {
			let semaphore = AsyncSemaphore(permits: 1)
			let started = OSAllocatedUnfairLock(initialState: false)
			let caller = _Concurrency.Task {
				try await semaphore.withPermit(budget: .seconds(60)) {
					started.withLock { $0 = true }
					try await _Concurrency.Task.sleep(for: .seconds(60))
				}
			}
			for _ in 0 ..< 100 where !started.withLock({ $0 }) {
				try await _Concurrency.Task.sleep(for: .milliseconds(10))
			}
			try #require(started.withLock { $0 })
			caller.cancel()
			await #expect(throws: CancellationError.self) {
				try await value(of: caller, timeout: .seconds(5))
			}
			try await value(of: _Concurrency.Task { await semaphore.acquire() }, timeout: .seconds(1))
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
		func timeoutWrappedByPCloudIsTransient() {
			let error = CallError<PCloudAPI.ListFolder.Error>.clientError(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
			#expect(isTransientIntegrationError(error))
		}

		@Test
		func tokenEndpointServerErrorOfAppAuthIsTransient() {
			let httpError = NSError(domain: "org.openid.appauth.remote-http", code: 500, userInfo: [NSLocalizedDescriptionKey: "Internal Server Error"])
			let error = NSError(domain: "org.openid.appauth.general", code: -6, userInfo: [
				NSUnderlyingErrorKey: httpError,
				NSLocalizedDescriptionKey: "Non-200 HTTP response (500) making token request to 'https://oauth2.googleapis.com/token'."
			])
			#expect(isTransientIntegrationError(error))
			let errorWithoutUnderlyingError = NSError(domain: error.domain, code: error.code, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
			#expect(isTransientIntegrationError(errorWithoutUnderlyingError))
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
				DropboxError.rateLimitError(retryAfter: 1),
				DropboxError.internalServerError,
				BoxAPIError(message: "Service Unavailable", requestInfo: RequestInfo(method: "GET", url: "https://api.box.com/2.0/folders/0", queryParams: [:], headers: [:]), responseInfo: ResponseInfo(statusCode: 503, headers: [:])),
				NSError(domain: "com.google.GTLRErrorObjectDomain", code: 503),
				NSError(domain: "com.google.HTTPStatus", code: 429),
				NSError(domain: "com.amazonaws.AWSS3ErrorDomain", code: 0, userInfo: ["Code": "SlowDown"]),
				CallError<PCloudAPI.ListFolder.Error>.rateLimitError,
				CallError<PCloudAPI.ListFolder.Error>.serverInternalError(5000, nil)
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
				NSError(domain: "com.google.HTTPStatus", code: 404)
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
	}
}

/// Keeps the continuations of hanging operations alive, so that they aren't reported as leaked.
private enum HangingContinuations {
	private static let continuations = OSAllocatedUnfairLock(initialState: [CheckedContinuation<Void, Never>]())

	static func keep(_ continuation: CheckedContinuation<Void, Never>) {
		continuations.withLock { $0.append(continuation) }
	}
}
