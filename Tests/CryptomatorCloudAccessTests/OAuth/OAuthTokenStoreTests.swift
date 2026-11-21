//
//  OAuthTokenStoreTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class OAuthTokenStoreTests {
		private static let tokenA = OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: nil)
		private static let tokenB = OAuthToken(accessToken: "B", refreshToken: "RB", expiresAt: nil)
		private static let tokenC = OAuthToken(accessToken: "C", refreshToken: "RC", expiresAt: nil)

		private let lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		private let buffer = TokenBuffer()

		deinit {
			guard FileManager.default.fileExists(atPath: lockDirectoryURL.path) else {
				return
			}
			removeItemRecordingFailure(at: lockDirectoryURL)
		}

		// MARK: - Stored Formats

		@Test
		func legacyTokenIsUsedWithoutRefreshAndRefreshSavesVersionedToken() async throws {
			buffer.data = Data(#"{"access_token":"LEGACY","refresh_token":"LEGACY-REFRESH","expires_in":3600,"token_type":"bearer","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","restricted_to":[{"scope":"item_download","object":{"type":"folder","id":"1"}},{"scope":"item_upload"}]}"#.utf8)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let store = try makeStore(refresher: refresher)

			let accessToken = try await store.accessToken()

			#expect(accessToken == "LEGACY")
			#expect(refresher.callCount == 0)

			let refreshedToken = try await store.refresh(rejecting: "LEGACY")

			#expect(refreshedToken == "B")
			#expect([OAuthToken(accessToken: "LEGACY", refreshToken: "LEGACY-REFRESH", expiresAt: nil)] == refresher.tokens)
			let storedData = try #require(buffer.data)
			let storedJSON = try #require(JSONSerialization.jsonObject(with: storedData) as? [String: Any])
			#expect((storedJSON["version"] as? Int) == 1)
			#expect((storedJSON["accessToken"] as? String) == "B")
		}

		@Test
		func versionedTokenKeepsItsStoredFormat() throws {
			let cases = [
				(#"{"version":1,"accessToken":"A","refreshToken":"RA","expiresAt":1800000000}"#, OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: Date(timeIntervalSince1970: 1_800_000_000))),
				(#"{"version":1,"accessToken":"A","apiHost":"eapi.pcloud.com"}"#, OAuthToken(accessToken: "A", refreshToken: nil, expiresAt: nil, apiHost: "eapi.pcloud.com"))
			]
			for (storedJSON, token) in cases {
				let decodedToken = try OAuthTokenEncoding.decode(Data(storedJSON.utf8), legacyDecoder: { _ in throw CocoaError(.coderReadCorrupt) })
				let encodedJSON = try JSONSerialization.jsonObject(with: OAuthTokenEncoding.encode(token)) as? NSDictionary

				#expect(token == decodedToken, "\(storedJSON)")
				#expect(try (JSONSerialization.jsonObject(with: Data(storedJSON.utf8)) as? NSDictionary) == encodedJSON, "\(storedJSON)")
			}
		}

		@Test
		func newerVersionThrowsWithoutOverwritingIt() async throws {
			let newerToken = Data(#"{"version":2,"accessToken":"A"}"#.utf8)
			buffer.data = newerToken
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let storage = MemoryTokenStorage(buffer: buffer)
			let store = try makeStore(storage: storage, refresher: refresher)

			await #expect(throws: OAuthTokenStoreError.unsupportedVersion(2)) { try await store.accessToken() }
			await #expect(throws: OAuthTokenStoreError.unsupportedVersion(2)) { try await store.refresh(rejecting: "A") }
			#expect(storage.saveCount == 0)
			#expect(refresher.callCount == 0)
			#expect(newerToken == buffer.data)
		}

		// MARK: - Coalescing

		@Test
		func concurrentRefreshesOfOneAccountShareOneRefresh() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let gate = Gate()
			let refresher = RefresherMock(wait: gate.wait) { _ in OAuthTokenStoreTests.tokenB }
			let acquisitions = OSAllocatedUnfairLock(initialState: 0)
			let lockEvents = CrossProcessFileLock.Events(acquired: { acquisitions.withLock { $0 += 1 } })
			let coordinator = OAuthTokenCoordinator()
			let firstStorage = MemoryTokenStorage(buffer: buffer)
			let secondStorage = MemoryTokenStorage(buffer: buffer)
			let firstStore = try makeStore(storage: firstStorage, refresher: refresher, lockEvents: lockEvents, coordinator: coordinator)
			let secondStore = try makeStore(storage: secondStorage, refresher: refresher, lockEvents: lockEvents, coordinator: coordinator)
			let callersStarted = TestSignal("callers started", expectedCount: 10)

			let callers = (0 ..< 10).map { index in
				let store = index.isMultiple(of: 2) ? firstStore : secondStore
				return Task { @MainActor in
					callersStarted.fulfill()
					return try await store.refresh(rejecting: "A")
				}
			}
			await callersStarted.wait()
			await refresher.entered.wait()
			await MainActor.run {
				gate.open()
			}

			for caller in callers {
				let accessToken = try await cancellingValue(of: caller)
				#expect(accessToken == "B")
			}
			#expect(refresher.callCount == 1)
			#expect(acquisitions.withLock { $0 } == 1)
			#expect(firstStorage.loadCount + secondStorage.loadCount == 1)
		}

		@Test
		func refreshInAnotherProcessIsReusedAfterWaitingForLock() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let gate = Gate()
			let firstRefresher = RefresherMock(wait: gate.wait) { _ in OAuthTokenStoreTests.tokenB }
			let secondRefresher = RefresherMock { _ in OAuthTokenStoreTests.tokenC }
			let contention = TestSignal("second process waits for the lock", allowsOverFulfillment: true)
			let firstStore = try makeStore(refresher: firstRefresher, coordinator: OAuthTokenCoordinator())
			let secondStore = try makeStore(refresher: secondRefresher, lockEvents: CrossProcessFileLock.Events(contention: { contention.fulfill() }), coordinator: OAuthTokenCoordinator())

			let firstRefresh = Task {
				try await firstStore.refresh(rejecting: "A")
			}
			await firstRefresher.entered.wait()
			let secondRefresh = Task {
				try await secondStore.refresh(rejecting: "A")
			}
			await contention.wait()
			gate.open()

			let firstAccessToken = try await cancellingValue(of: firstRefresh)
			let secondAccessToken = try await cancellingValue(of: secondRefresh)
			#expect(firstAccessToken == "B")
			#expect(secondAccessToken == "B")
			#expect(secondRefresher.callCount == 0)
		}

		@Test
		func staleRejectionReturnsStoredTokenWithoutRefresh() async throws {
			buffer.store(OAuthTokenStoreTests.tokenB)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenC }
			let store = try makeStore(refresher: refresher)

			let accessToken = try await store.refresh(rejecting: "A")

			#expect(accessToken == "B")
			#expect(refresher.callCount == 0)
		}

		// MARK: - Expiry

		@Test
		func accessTokenIsRefreshedWithinFiveMinutesOfExpiry() async throws {
			let now = Date()
			for (minutesAhead, expectedAccessToken, expectedCallCount) in [(4.0, "B", 1), (6.0, "A", 0)] {
				buffer.store(OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: now.addingTimeInterval(minutesAhead * 60)))
				let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
				let store = try makeStore(refresher: refresher, now: { now }, coordinator: OAuthTokenCoordinator())

				let accessToken = try await store.accessToken()

				#expect(expectedAccessToken == accessToken, "\(minutesAhead) minutes ahead")
				#expect(expectedCallCount == refresher.callCount, "\(minutesAhead) minutes ahead")
			}
		}

		@Test
		func failedRefreshBeforeExpiryReturnsCurrentTokenAndThrowsAfterExpiry() async throws {
			let now = Date()
			for (minutesAhead, throwsError) in [(4.0, false), (-1.0, true)] {
				buffer.store(OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: now.addingTimeInterval(minutesAhead * 60)))
				let refresher = RefresherMock { _ in throw URLError(.timedOut) }
				let store = try makeStore(refresher: refresher, now: { now }, coordinator: OAuthTokenCoordinator())

				do {
					let accessToken = try await store.accessToken()
					#expect(!throwsError, "\(minutesAhead) minutes ahead")
					#expect(accessToken == "A")
				} catch {
					#expect(throwsError, "\(minutesAhead) minutes ahead")
					#expect((error as? URLError)?.code == .timedOut)
				}
			}
		}

		// MARK: - Failures

		@Test
		func cancelledCallerDoesNotCancelSharedRefresh() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let gate = Gate()
			let refresher = RefresherMock(wait: gate.wait) { _ in OAuthTokenStoreTests.tokenB }
			let storage = MemoryTokenStorage(buffer: buffer)
			let store = try makeStore(storage: storage, refresher: refresher)

			let cancelledCaller = Task {
				try await store.refresh(rejecting: "A")
			}
			await refresher.entered.wait()
			let otherCaller = Task {
				try await store.refresh(rejecting: "A")
			}
			cancelledCaller.cancel()
			gate.open()

			let accessToken = try await cancellingValue(of: otherCaller)
			_ = try? await cancellingValue(of: cancelledCaller)
			#expect(accessToken == "B")
			#expect(storage.saveCount == 1)
			#expect(OAuthTokenStoreTests.tokenB == buffer.token)
		}

		@Test
		func refresherErrorReachesAllWaitersAndNextCallRefreshesAgain() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let gate = Gate()
			let refresher = RefresherMock(wait: gate.wait) { callCount in
				guard callCount > 1 else {
					throw URLError(.timedOut)
				}
				return OAuthTokenStoreTests.tokenB
			}
			let storage = MemoryTokenStorage(buffer: buffer)
			let store = try makeStore(storage: storage, refresher: refresher)
			let callersStarted = TestSignal("callers started", expectedCount: 2)

			let callers = (0 ..< 2).map { _ in
				Task { @MainActor in
					callersStarted.fulfill()
					return try await store.refresh(rejecting: "A")
				}
			}
			await callersStarted.wait()
			await refresher.entered.wait()
			await MainActor.run {
				gate.open()
			}
			for caller in callers {
				let error = try await #require(throws: (any Error).self) { try await cancellingValue(of: caller) }
				#expect((error as? URLError)?.code == .timedOut)
			}
			#expect(storage.saveCount == 0)

			let accessToken = try await store.refresh(rejecting: "A")

			#expect(accessToken == "B")
			#expect(refresher.callCount == 2)
		}

		@Test
		func rejectedRefreshDeletesNothing() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let store = try makeStore(refresher: RefresherMock { _ in throw CloudProviderError.unauthorized })

			await #expect(throws: CloudProviderError.unauthorized) { try await store.refresh(rejecting: "A") }
			#expect(OAuthTokenStoreTests.tokenA == buffer.token)
		}

		@Test
		func missingStoredTokenThrowsUnauthorizedWithoutRefresh() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let store = try makeStore(refresher: refresher)
			_ = try await store.accessToken()
			buffer.data = nil

			await #expect(throws: CloudProviderError.unauthorized) { try await store.refresh(rejecting: "A") }
			await #expect(throws: CloudProviderError.unauthorized) { try await store.accessToken() }
			#expect(refresher.callCount == 0)
		}

		@Test
		func unsavedTokenIsSavedBeforeNextRefresh() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let storage = MemoryTokenStorage(buffer: buffer)
			storage.failsSaves = true
			let store = try makeStore(storage: storage, refresher: refresher)

			let rotatedAccessToken = try await store.refresh(rejecting: "A")
			let currentAccessToken = try await store.accessToken()

			#expect(rotatedAccessToken == "B")
			#expect(currentAccessToken == "B")
			#expect(OAuthTokenStoreTests.tokenA == buffer.token)

			storage.failsSaves = false
			let accessToken = try await store.refresh(rejecting: "A")

			#expect(accessToken == "B")
			#expect(refresher.callCount == 1)
			#expect(OAuthTokenStoreTests.tokenB == buffer.token)
		}

		@Test
		func unsavedTokenDoesNotRestoreDeletedOrReplacedLogin() async throws {
			for replacesLogin in [false, true] {
				buffer.store(OAuthTokenStoreTests.tokenA)
				let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
				let storage = MemoryTokenStorage(buffer: buffer)
				storage.failsSaves = true
				let store = try makeStore(storage: storage, refresher: refresher, coordinator: OAuthTokenCoordinator())
				let otherProcessStore = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenC }, coordinator: OAuthTokenCoordinator())
				_ = try await store.refresh(rejecting: "A")
				storage.failsSaves = false

				if replacesLogin {
					try await otherProcessStore.replace(with: OAuthTokenStoreTests.tokenC)
					let accessToken = try await store.refresh(rejecting: "B")
					#expect(accessToken == "C")
					#expect(OAuthTokenStoreTests.tokenC == buffer.token)
				} else {
					try await otherProcessStore.delete(revoking: { _ in })
					await #expect(throws: CloudProviderError.unauthorized) { try await store.refresh(rejecting: "B") }
					#expect(buffer.data == nil)
				}
				#expect(refresher.callCount == 1)
			}
		}

		@Test
		func deleteRevokesUnsavedToken() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let storage = MemoryTokenStorage(buffer: buffer)
			storage.failsSaves = true
			let store = try makeStore(storage: storage, refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })
			_ = try await store.refresh(rejecting: "A")
			let revokedTokens = OSAllocatedUnfairLock(initialState: [OAuthToken]())

			try await store.delete(revoking: { token in
				revokedTokens.withLock { $0.append(token) }
			})

			#expect([OAuthTokenStoreTests.tokenB] == revokedTokens.withLock { $0 })
			#expect(buffer.data == nil)
		}

		// MARK: - Execution Assertion

		@Test
		func refreshWithoutExecutionTimeThrowsWithoutRequest() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let store = try makeStore(refresher: refresher, script: ActivityScript(refusesAssertions: true))

			let callers = (0 ..< 2).map { _ in
				Task {
					try await store.refresh(rejecting: "A")
				}
			}

			for caller in callers {
				await #expect(throws: OAuthTokenStoreError.executionTimeUnavailable) { try await cancellingValue(of: caller) }
			}
			#expect(refresher.callCount == 0)
		}

		@Test
		func expiryWhileWaitingForLockThrowsWithoutRequest() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let script = ActivityScript()
			let contention = TestSignal("refresh waits for the lock", allowsOverFulfillment: true)
			let store = try makeStore(refresher: refresher, script: script, lockEvents: CrossProcessFileLock.Events(contention: { contention.fulfill() }))
			let otherHolder = try await store.makeLock().acquire(timeout: testWaitTimeout, pollInterval: .milliseconds(10))

			let refresh = Task {
				try await store.refresh(rejecting: "A")
			}
			await contention.wait()
			script.expireRunningAssertion()
			otherHolder.release()

			await #expect(throws: OAuthTokenStoreError.executionTimeUnavailable) { try await cancellingValue(of: refresh) }
			#expect(refresher.callCount == 0)
		}

		@Test
		func expiryWhileLoadingStoredTokenThrowsWithoutRequest() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let script = ActivityScript()
			let storage = MemoryTokenStorage(buffer: buffer, onLoad: { script.expireRunningAssertion() })
			let store = try makeStore(storage: storage, refresher: refresher, script: script)

			await #expect(throws: OAuthTokenStoreError.executionTimeUnavailable) { try await store.refresh(rejecting: "A") }
			#expect(refresher.callCount == 0)
		}

		@Test
		func expiryWhileLoadingUnsavedTokensSourceKeepsItUnsaved() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let script = ActivityScript()
			let expiresOnLoad = OSAllocatedUnfairLock(initialState: false)
			let storage = MemoryTokenStorage(buffer: buffer, onLoad: {
				if expiresOnLoad.withLock({ $0 }) {
					script.expireRunningAssertion()
				}
			})
			storage.failsSaves = true
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let store = try makeStore(storage: storage, refresher: refresher, script: script)
			_ = try await store.refresh(rejecting: "A")
			storage.failsSaves = false
			expiresOnLoad.withLock { $0 = true }

			await #expect(throws: OAuthTokenStoreError.executionTimeUnavailable) { try await store.refresh(rejecting: "A") }
			#expect(OAuthTokenStoreTests.tokenA == buffer.token)

			expiresOnLoad.withLock { $0 = false }
			let accessToken = try await store.refresh(rejecting: "A")

			#expect(accessToken == "B")
			#expect(OAuthTokenStoreTests.tokenB == buffer.token)
			#expect(refresher.callCount == 1)
		}

		@Test
		func expiryWhileDeletingKeepsItemWithoutRevocation() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let script = ActivityScript()
			let storage = MemoryTokenStorage(buffer: buffer, onLoad: { script.expireRunningAssertion() })
			let store = try makeStore(storage: storage, refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, script: script)
			let revocationCount = OSAllocatedUnfairLock(initialState: 0)

			await #expect(throws: OAuthTokenStoreError.executionTimeUnavailable) {
				try await store.delete(revoking: { _ in
					revocationCount.withLock { $0 += 1 }
				})
			}
			#expect(revocationCount.withLock { $0 } == 0)
			#expect(OAuthTokenStoreTests.tokenA == buffer.token)
		}

		@Test
		func expiryDuringStorageWriteReleasesLockAfterWrite() async throws {
			for write in ["save", "delete"] {
				buffer.store(OAuthTokenStoreTests.tokenA)
				let script = ActivityScript()
				let writeStarted = TestSignal("write started")
				let writeGate = DispatchSemaphore(value: 0)
				let storage = MemoryTokenStorage(buffer: buffer, onWrite: {
					writeStarted.fulfill()
					_ = writeGate.wait(timeout: testWaitDeadline())
				})
				let store = try makeStore(storage: storage, refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, script: script)
				let operation = Task {
					if write == "save" {
						try await store.replace(with: OAuthTokenStoreTests.tokenC)
					} else {
						try await store.delete(revoking: { _ in })
					}
				}
				await writeStarted.wait()
				let expiryStarted = TestSignal("expiry started")
				let expiryReturned = TestSignal("expiry returned")
				// The expiry waits for the write, so it runs on another thread.
				DispatchQueue.global().async {
					expiryStarted.fulfill()
					script.expireRunningAssertion()
					expiryReturned.fulfill()
				}
				await expiryStarted.wait()

				await #expect(throws: OAuthTokenStoreError.lockTimeout, "\(write)") { try await store.makeLock().acquire(timeout: .milliseconds(500), pollInterval: .milliseconds(10)) }
				writeGate.signal()
				try await cancellingValue(of: operation)
				await expiryReturned.wait()
				let otherHolder = try await store.makeLock().acquire(timeout: testWaitTimeout, pollInterval: .milliseconds(10))
				otherHolder.release()

				#expect((write == "save" ? OAuthTokenStoreTests.tokenC : nil) == buffer.token, "\(write)")
			}
		}

		@Test
		func deleteReleasesLockBeforeRevoking() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let store = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, coordinator: OAuthTokenCoordinator())
			let otherProcessStore = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, coordinator: OAuthTokenCoordinator())
			let revocationStarted = TestSignal("revocation started")
			let revocationReleased = TestSignal("revocation released")

			let delete = Task {
				try await store.delete(revoking: { _ in
					revocationStarted.fulfill()
					await revocationReleased.wait()
				})
			}
			await revocationStarted.wait()
			try await releasingOnError(delete, by: revocationReleased) {
				try await cancellingValue(of: Task {
					try await otherProcessStore.replace(with: OAuthTokenStoreTests.tokenC)
				})
			}
			revocationReleased.fulfill()

			try await cancellingValue(of: delete)
			#expect(OAuthTokenStoreTests.tokenC == buffer.token)
		}

		@Test
		func expiryDuringRefreshReleasesLockAndLateResponseIsSavedOnlyOverItsSource() async throws {
			for meanwhile in ["nothing", "delete", "replace"] {
				buffer.store(OAuthTokenStoreTests.tokenA)
				let lateRefresh = try await startLateRefresh(storage: MemoryTokenStorage(buffer: buffer), script: ActivityScript())
				lateRefresh.otherHolder.release()
				try await releasingOnError(lateRefresh.refresh, by: lateRefresh.refreshReleased) {
					let otherProcessStore = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenC }, coordinator: OAuthTokenCoordinator())
					if meanwhile == "delete" {
						try await otherProcessStore.delete(revoking: { _ in })
					} else if meanwhile == "replace" {
						try await otherProcessStore.replace(with: OAuthTokenStoreTests.tokenC)
					}
				}
				lateRefresh.refreshReleased.fulfill()

				if meanwhile == "delete" {
					await #expect(throws: CloudProviderError.unauthorized) { try await cancellingValue(of: lateRefresh.refresh) }
					#expect(buffer.data == nil)
				} else {
					let expectedToken = meanwhile == "replace" ? OAuthTokenStoreTests.tokenC : OAuthTokenStoreTests.tokenB
					let accessToken = try await cancellingValue(of: lateRefresh.refresh)
					let currentAccessToken = try await lateRefresh.store.accessToken()
					#expect(expectedToken.accessToken == accessToken, "\(meanwhile)")
					#expect(expectedToken.accessToken == currentAccessToken, "\(meanwhile)")
					#expect(expectedToken == buffer.token, "\(meanwhile)")
				}
			}
		}

		@Test
		func lateResponseThatCannotBeSavedNowIsSavedBeforeNextRefresh() async throws {
			for failure in ["assertion refused", "lock timeout", "load failure", "expiry while loading"] {
				buffer.store(OAuthTokenStoreTests.tokenA)
				let script = ActivityScript()
				let expiresOnLoad = OSAllocatedUnfairLock(initialState: false)
				let storage = MemoryTokenStorage(buffer: buffer, onLoad: {
					if expiresOnLoad.withLock({ $0 }) {
						script.expireRunningAssertion()
					}
				})
				let lateRefresh = try await startLateRefresh(storage: storage, script: script, lockTimeout: failure == "lock timeout" ? .milliseconds(100) : testWaitTimeout)
				switch failure {
				case "assertion refused":
					script.refusesAssertions = true
				case "load failure":
					storage.failsLoads = true
				case "expiry while loading":
					expiresOnLoad.withLock { $0 = true }
				default:
					break
				}
				if failure != "lock timeout" {
					lateRefresh.otherHolder.release()
				}
				lateRefresh.refreshReleased.fulfill()

				let accessToken = try await cancellingValue(of: lateRefresh.refresh)

				#expect(accessToken == "B", "\(failure)")
				#expect(OAuthTokenStoreTests.tokenA == buffer.token, "\(failure)")

				lateRefresh.otherHolder.release()
				script.refusesAssertions = false
				storage.failsLoads = false
				expiresOnLoad.withLock { $0 = false }
				let savedAccessToken = try await lateRefresh.store.refresh(rejecting: "A")

				#expect(savedAccessToken == "B", "\(failure)")
				#expect(OAuthTokenStoreTests.tokenB == buffer.token, "\(failure)")
				#expect(lateRefresh.refresher.callCount == 1, "\(failure)")
			}
		}

		// MARK: - Lock Timeout

		@Test
		func lockTimeoutReturnsChangedStoredTokenAndOtherwiseThrows() async throws {
			buffer.store(OAuthTokenStoreTests.tokenB)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenC }
			let store = try makeStore(refresher: refresher, lockTimeout: .milliseconds(100))
			let otherHolder = try await store.makeLock().acquire(timeout: testWaitTimeout, pollInterval: .milliseconds(10))
			defer {
				otherHolder.release()
			}

			let accessToken = try await store.refresh(rejecting: "A")

			#expect(accessToken == "B")
			await #expect(throws: OAuthTokenStoreError.lockTimeout) { try await store.refresh(rejecting: "B") }
			#expect(refresher.callCount == 0)
		}

		@Test
		func lockTimeoutWithUnsavedTokenThrowsAndKeepsIt() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let storage = MemoryTokenStorage(buffer: buffer)
			storage.failsSaves = true
			let store = try makeStore(storage: storage, refresher: refresher, lockTimeout: .milliseconds(100))
			_ = try await store.refresh(rejecting: "A")
			storage.failsSaves = false
			let otherHolder = try await store.makeLock().acquire(timeout: testWaitTimeout, pollInterval: .milliseconds(10))

			await #expect(throws: OAuthTokenStoreError.lockTimeout) { try await store.refresh(rejecting: "B") }
			otherHolder.release()
			let accessToken = try await store.refresh(rejecting: "A")

			#expect(accessToken == "B")
			#expect(OAuthTokenStoreTests.tokenB == buffer.token)
			#expect(refresher.callCount == 1)
		}

		// MARK: - Delete

		@Test
		func deleteDeletesAlsoIfRevocationFails() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let store = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })

			let error = try await #require(throws: (any Error).self) { try await store.delete(revoking: { _ in throw URLError(.timedOut) }) }
			#expect((error as? URLError)?.code == .timedOut)
			#expect(buffer.data == nil)
		}

		@Test
		func deleteOfMissingOrUndecodableItemSkipsRevocation() async throws {
			for storedData in [nil, Data("garbage".utf8)] {
				buffer.data = storedData
				let store = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })
				let revocationCount = OSAllocatedUnfairLock(initialState: 0)

				try await store.delete(revoking: { _ in
					revocationCount.withLock { $0 += 1 }
				})

				#expect(revocationCount.withLock { $0 } == 0)
				#expect(buffer.data == nil)
			}
		}

		// MARK: - Username

		@Test
		func refreshKeepsStoredUsername() async throws {
			buffer.store(OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: nil, username: "Name"))
			let store = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })

			_ = try await store.refresh(rejecting: "A")

			#expect(OAuthToken(accessToken: "B", refreshToken: "RB", expiresAt: nil, username: "Name") == buffer.token)
			#expect(try store.storedUsername() == "Name")
		}

		@Test
		func updateUsernameWritesUnderLockAndIsRefusedAfterExpiry() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let acquisitions = OSAllocatedUnfairLock(initialState: 0)
			let store = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, lockEvents: CrossProcessFileLock.Events(acquired: { acquisitions.withLock { $0 += 1 } }))

			try await store.updateUsername("Name")

			#expect(OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: nil, username: "Name") == buffer.token)
			#expect(acquisitions.withLock { $0 } == 1)

			let script = ActivityScript()
			let expiringStore = try makeStore(storage: MemoryTokenStorage(buffer: buffer, onLoad: { script.expireRunningAssertion() }), refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, script: script)

			await #expect(throws: OAuthTokenStoreError.executionTimeUnavailable) { try await expiringStore.updateUsername("Other") }
			#expect(buffer.token?.username == "Name")
		}

		@Test
		func updateUsernameWithoutStoredLoginThrowsUnauthorized() async throws {
			let store = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })

			await #expect(throws: CloudProviderError.unauthorized) { try await store.updateUsername("Name") }
			#expect(buffer.data == nil)
		}

		/// The username is stored with the tokens that the rotated token replaces, so the next refresh still saves the rotated token before sending its refresh token.
		@Test
		func updateUsernameKeepsUnsavedToken() async throws {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { callCount in callCount == 1 ? OAuthTokenStoreTests.tokenB : OAuthTokenStoreTests.tokenC }
			let storage = MemoryTokenStorage(buffer: buffer)
			storage.failsSaves = true
			let store = try makeStore(storage: storage, refresher: refresher)
			_ = try await store.refresh(rejecting: "A")
			storage.failsSaves = false

			try await store.updateUsername("Name")
			let accessToken = try await store.refresh(rejecting: "B")

			#expect(accessToken == "C")
			#expect(refresher.tokens.map(\.refreshToken) == ["RA", "RB"])
			#expect(OAuthToken(accessToken: "C", refreshToken: "RC", expiresAt: nil, username: "Name") == buffer.token)
		}

		@Test
		func tokensSavedLaterKeepUsernameStoredMeanwhile() async throws {
			let otherProcessStore = try makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenC }, coordinator: OAuthTokenCoordinator())

			buffer.store(OAuthTokenStoreTests.tokenA)
			let lateRefresh = try await startLateRefresh(storage: MemoryTokenStorage(buffer: buffer), script: ActivityScript())
			lateRefresh.otherHolder.release()
			try await releasingOnError(lateRefresh.refresh, by: lateRefresh.refreshReleased) {
				try await otherProcessStore.updateUsername("Late")
			}
			lateRefresh.refreshReleased.fulfill()
			_ = try await cancellingValue(of: lateRefresh.refresh)

			#expect(OAuthToken(accessToken: "B", refreshToken: "RB", expiresAt: nil, username: "Late") == buffer.token)

			buffer.store(OAuthTokenStoreTests.tokenA)
			let storage = MemoryTokenStorage(buffer: buffer)
			storage.failsSaves = true
			let store = try makeStore(storage: storage, refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, coordinator: OAuthTokenCoordinator())
			_ = try await store.refresh(rejecting: "A")
			storage.failsSaves = false
			try await otherProcessStore.updateUsername("Unsaved")
			_ = try await store.refresh(rejecting: "A")

			#expect(OAuthToken(accessToken: "B", refreshToken: "RB", expiresAt: nil, username: "Unsaved") == buffer.token)
		}

		// MARK: - Persistence

		@Test
		func lockDirectoryMustBeFileURL() throws {
			let url = try #require(URL(string: "https://example.com/locks"))
			for persistence in [{ try OAuthPersistence.keychain(accessGroup: nil, tokenLockDirectory: url) }, { try OAuthPersistence.custom(storage: MemoryTokenStorage(buffer: TokenBuffer()), tokenLockDirectory: url) }] {
				#expect(throws: OAuthTokenStoreError.invalidLockDirectory) { try persistence() }
			}
		}

		@Test
		func testLegacyDropboxService() {
			#expect(OAuthPersistence.legacyDropboxService(keychainService: "org.cryptomator.ios") == "org.cryptomator.ios.dropbox.authv2")
		}

		// MARK: - Helpers

		/// Starts a refresh of token A to token B whose assertion expires while the refresher waits for `refreshReleased`. Returns once another holder acquired the lock that the refresh released.
		private func startLateRefresh(storage: MemoryTokenStorage, script: ActivityScript, lockTimeout: Duration = testWaitTimeout) async throws -> LateRefresh {
			let refreshReleased = TestSignal("late refresh released")
			let refresher = RefresherMock(wait: { await refreshReleased.wait() }, result: { _ in OAuthTokenStoreTests.tokenB })
			let store = try makeStore(storage: storage, refresher: refresher, script: script, lockTimeout: lockTimeout, coordinator: OAuthTokenCoordinator())
			let refresh = Task {
				try await store.refresh(rejecting: "A")
			}
			await refresher.entered.wait()
			script.expireRunningAssertion()
			let otherHolder = try await releasingOnError(refresh, by: refreshReleased) {
				try await cancellingValue(of: Task {
					try await store.makeLock().acquire(timeout: testWaitTimeout, pollInterval: .milliseconds(10))
				})
			}
			return LateRefresh(store: store, refresher: refresher, refreshReleased: refreshReleased, refresh: refresh, otherHolder: otherHolder)
		}

		private func makeStore(storage: MemoryTokenStorage? = nil, refresher: RefresherMock, script: ActivityScript = ActivityScript(), now: @escaping @Sendable () -> Date = Date.init, lockTimeout: Duration = testWaitTimeout, lockEvents: CrossProcessFileLock.Events = .init(), coordinator: OAuthTokenCoordinator = OAuthTokenCoordinator()) throws -> OAuthTokenStore {
			return try OAuthTokenStore(provider: OAuthProvider(rawValue: "test"), account: "user", persistence: .custom(storage: storage ?? MemoryTokenStorage(buffer: buffer), tokenLockDirectory: lockDirectoryURL), legacyDecoder: BoxLegacyToken.decode, refresher: { try await refresher.refresh($0) }, assertion: script.assertion, now: now, lockTimeout: lockTimeout, lockPollInterval: .milliseconds(10), lockEvents: lockEvents, coordinator: coordinator)
		}
	}
}

private struct LateRefresh {
	let store: OAuthTokenStore
	let refresher: RefresherMock
	let refreshReleased: TestSignal
	let refresh: Task<String, Error>
	/// Holds the lock that the refresh released when its assertion expired.
	let otherHolder: CrossProcessFileLock.Holder
}

/// The persisted item of one account, which several storage objects can share, as the processes of an app share a keychain item.
final class TokenBuffer: Sendable {
	private let storedData = OSAllocatedUnfairLock<Data?>(initialState: nil)

	var data: Data? {
		get { storedData.withLock { $0 } }
		set { storedData.withLock { $0 = newValue } }
	}

	var token: OAuthToken? {
		return data.flatMap { try? OAuthTokenEncoding.decode($0, legacyDecoder: BoxLegacyToken.decode) }
	}

	func store(_ token: OAuthToken) {
		data = try? OAuthTokenEncoding.encode(token)
	}
}

/// Keeps one token whatever the account key, and records the keys that it was accessed with.
final class MemoryTokenStorage: OAuthTokenStorage {
	private struct State {
		var loadCount = 0
		var saveCount = 0
		var failsLoads = false
		var failsSaves = false
		var keys = Set<OAuthAccountKey>()
	}

	private let buffer: TokenBuffer
	private let onLoad: @Sendable () -> Void
	private let onWrite: @Sendable () -> Void
	private let state = OSAllocatedUnfairLock(initialState: State())

	init(buffer: TokenBuffer, onLoad: @escaping @Sendable () -> Void = {}, onWrite: @escaping @Sendable () -> Void = {}) {
		self.buffer = buffer
		self.onLoad = onLoad
		self.onWrite = onWrite
	}

	var loadCount: Int {
		return state.withLock { $0.loadCount }
	}

	var saveCount: Int {
		return state.withLock { $0.saveCount }
	}

	var keys: Set<OAuthAccountKey> {
		return state.withLock { $0.keys }
	}

	var failsLoads: Bool {
		get { state.withLock { $0.failsLoads } }
		set { state.withLock { $0.failsLoads = newValue } }
	}

	var failsSaves: Bool {
		get { state.withLock { $0.failsSaves } }
		set { state.withLock { $0.failsSaves = newValue } }
	}

	func load(_ key: OAuthAccountKey) throws -> Data? {
		let failsLoads = state.withLock { state in
			state.loadCount += 1
			state.keys.insert(key)
			return state.failsLoads
		}
		onLoad()
		guard !failsLoads else {
			throw CocoaError(.fileReadUnknown)
		}
		return buffer.data
	}

	func save(_ data: Data, for key: OAuthAccountKey) throws {
		try state.withLock { state in
			state.keys.insert(key)
			guard !state.failsSaves else {
				throw CocoaError(.fileWriteUnknown)
			}
			state.saveCount += 1
		}
		onWrite()
		buffer.data = data
	}

	func delete(_ key: OAuthAccountKey) throws {
		state.withLock { _ = $0.keys.insert(key) }
		onWrite()
		buffer.data = nil
	}
}

/// Records the tokens of the refreshes and holds each back until `wait` returns.
final class RefresherMock: Sendable {
	let entered = TestSignal("refresher entered", allowsOverFulfillment: true)
	private let wait: @Sendable () async -> Void
	private let result: @Sendable (_ callCount: Int) throws -> OAuthToken
	private let receivedTokens = OSAllocatedUnfairLock(initialState: [OAuthToken]())

	init(wait: @escaping @Sendable () async -> Void = {}, result: @escaping @Sendable (_ callCount: Int) throws -> OAuthToken) {
		self.wait = wait
		self.result = result
	}

	var callCount: Int {
		return receivedTokens.withLock { $0.count }
	}

	var tokens: [OAuthToken] {
		return receivedTokens.withLock { $0 }
	}

	func refresh(_ token: OAuthToken) async throws -> OAuthToken {
		let callCount = receivedTokens.withLock { tokens in
			tokens.append(token)
			return tokens.count
		}
		entered.fulfill()
		await wait()
		return try result(callCount)
	}
}

/// Drives the blocks of `performExpiringActivity(withReason:using:)` as the system does: it grants or refuses each new assertion, and can expire the running one.
final class ActivityScript: Sendable {
	private let state: OSAllocatedUnfairLock<(refusesAssertions: Bool, blocks: [@Sendable (Bool) -> Void])>

	init(refusesAssertions: Bool = false) {
		self.state = OSAllocatedUnfairLock(initialState: (refusesAssertions: refusesAssertions, blocks: []))
	}

	/// Whether new assertions are refused, as when the process has no background time left.
	var refusesAssertions: Bool {
		get { state.withLock { $0.refusesAssertions } }
		set { state.withLock { $0.refusesAssertions = newValue } }
	}

	var assertion: ProcessExecutionAssertion {
		return ProcessExecutionAssertion(performActivity: { _, block in
			let expired = self.state.withLock { state in
				state.blocks.append(block)
				return state.refusesAssertions
			}
			DispatchQueue.global().async {
				block(expired)
			}
		})
	}

	/// Calls the block of the latest assertion with `true`, as when its time runs out.
	func expireRunningAssertion() {
		state.withLock { $0.blocks.last }?(true)
	}
}
