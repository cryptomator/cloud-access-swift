//
//  OAuthTokenStoreTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 20.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class OAuthTokenStoreTests: XCTestCase {
	private static let tokenA = OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: nil)
	private static let tokenB = OAuthToken(accessToken: "B", refreshToken: "RB", expiresAt: nil)
	private static let tokenC = OAuthToken(accessToken: "C", refreshToken: "RC", expiresAt: nil)

	private var lockDirectoryURL: URL!
	private var buffer: TokenBuffer!

	override func setUpWithError() throws {
		lockDirectoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		buffer = TokenBuffer()
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: lockDirectoryURL)
	}

	// MARK: - Stored Formats

	func testLegacyTokenIsUsedWithoutRefreshAndRefreshSavesVersionedToken() async throws {
		buffer.data = Data(#"{"access_token":"LEGACY","refresh_token":"LEGACY-REFRESH","expires_in":3600,"token_type":"bearer","issued_token_type":"urn:ietf:params:oauth:token-type:access_token","restricted_to":[{"scope":"item_download","object":{"type":"folder","id":"1"}},{"scope":"item_upload"}]}"#.utf8)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let store = makeStore(refresher: refresher)

		let accessToken = try await store.accessToken()

		XCTAssertEqual("LEGACY", accessToken)
		XCTAssertEqual(0, refresher.callCount)

		let refreshedToken = try await store.refresh(rejecting: "LEGACY")

		XCTAssertEqual("B", refreshedToken)
		XCTAssertEqual([OAuthToken(accessToken: "LEGACY", refreshToken: "LEGACY-REFRESH", expiresAt: nil)], refresher.tokens)
		let storedJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(buffer.data)) as? [String: Any])
		XCTAssertEqual(1, storedJSON["version"] as? Int)
		XCTAssertEqual("B", storedJSON["accessToken"] as? String)
	}

	func testVersionedTokenKeepsItsStoredFormat() throws {
		let storedJSON = #"{"version":1,"accessToken":"A","refreshToken":"RA","expiresAt":1800000000}"#
		let token = OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: Date(timeIntervalSince1970: 1_800_000_000))

		let decodedToken = try OAuthTokenEncoding.decode(Data(storedJSON.utf8), legacyDecoder: { _ in throw CocoaError(.coderReadCorrupt) })
		let encodedJSON = try JSONSerialization.jsonObject(with: OAuthTokenEncoding.encode(token)) as? NSDictionary

		XCTAssertEqual(token, decodedToken)
		XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(storedJSON.utf8)) as? NSDictionary, encodedJSON)
	}

	func testNewerVersionThrowsWithoutOverwritingIt() async throws {
		let newerToken = Data(#"{"version":2,"accessToken":"A"}"#.utf8)
		buffer.data = newerToken
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let storage = MemoryTokenStorage(buffer: buffer)
		let store = makeStore(storage: storage, refresher: refresher)

		await XCTAssertThrowsErrorAsync(try await store.accessToken()) { error in
			XCTAssertEqual(.unsupportedVersion(2), error as? OAuthTokenStoreError)
		}
		await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "A")) { error in
			XCTAssertEqual(.unsupportedVersion(2), error as? OAuthTokenStoreError)
		}
		XCTAssertEqual(0, storage.saveCount)
		XCTAssertEqual(0, refresher.callCount)
		XCTAssertEqual(newerToken, buffer.data)
	}

	// MARK: - Coalescing

	func testConcurrentRefreshesOfOneAccountShareOneRefresh() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let gate = Gate()
		let refresher = RefresherMock(gate: gate) { _ in OAuthTokenStoreTests.tokenB }
		let acquisitions = OSAllocatedUnfairLock(initialState: 0)
		let lockEvents = CrossProcessFileLock.Events(acquired: { acquisitions.withLock { $0 += 1 } })
		let coordinator = OAuthTokenCoordinator()
		let firstStorage = MemoryTokenStorage(buffer: buffer)
		let secondStorage = MemoryTokenStorage(buffer: buffer)
		let firstStore = makeStore(storage: firstStorage, refresher: refresher, lockEvents: lockEvents, coordinator: coordinator)
		let secondStore = makeStore(storage: secondStorage, refresher: refresher, lockEvents: lockEvents, coordinator: coordinator)
		let callersStarted = XCTestExpectation(description: "callers started")
		callersStarted.expectedFulfillmentCount = 10

		let callers = (0 ..< 10).map { index in
			let store = index.isMultiple(of: 2) ? firstStore : secondStore
			return Task { @MainActor in
				callersStarted.fulfill()
				return try await store.refresh(rejecting: "A")
			}
		}
		await fulfillment(of: [callersStarted, refresher.entered], timeout: testWaitTimeout)
		await MainActor.run {
			gate.open()
		}

		for caller in callers {
			let accessToken = try await value(of: caller)
			XCTAssertEqual("B", accessToken)
		}
		XCTAssertEqual(1, refresher.callCount)
		XCTAssertEqual(1, acquisitions.withLock { $0 })
		XCTAssertEqual(1, firstStorage.loadCount + secondStorage.loadCount)
	}

	func testRefreshInAnotherProcessIsReusedAfterWaitingForLock() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let gate = Gate()
		let firstRefresher = RefresherMock(gate: gate) { _ in OAuthTokenStoreTests.tokenB }
		let secondRefresher = RefresherMock { _ in OAuthTokenStoreTests.tokenC }
		let contention = XCTestExpectation(description: "second process waits for the lock")
		contention.assertForOverFulfill = false
		let firstStore = makeStore(refresher: firstRefresher, coordinator: OAuthTokenCoordinator())
		let secondStore = makeStore(refresher: secondRefresher, lockEvents: CrossProcessFileLock.Events(contention: { contention.fulfill() }), coordinator: OAuthTokenCoordinator())

		let firstRefresh = Task {
			try await firstStore.refresh(rejecting: "A")
		}
		await fulfillment(of: [firstRefresher.entered], timeout: testWaitTimeout)
		let secondRefresh = Task {
			try await secondStore.refresh(rejecting: "A")
		}
		await fulfillment(of: [contention], timeout: testWaitTimeout)
		gate.open()

		let firstAccessToken = try await value(of: firstRefresh)
		let secondAccessToken = try await value(of: secondRefresh)
		XCTAssertEqual("B", firstAccessToken)
		XCTAssertEqual("B", secondAccessToken)
		XCTAssertEqual(0, secondRefresher.callCount)
	}

	func testStaleRejectionReturnsStoredTokenWithoutRefresh() async throws {
		buffer.store(OAuthTokenStoreTests.tokenB)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenC }
		let store = makeStore(refresher: refresher)

		let accessToken = try await store.refresh(rejecting: "A")

		XCTAssertEqual("B", accessToken)
		XCTAssertEqual(0, refresher.callCount)
	}

	// MARK: - Expiry

	func testAccessTokenIsRefreshedWithinFiveMinutesOfExpiry() async throws {
		let now = Date()
		for (minutesAhead, expectedAccessToken, expectedCallCount) in [(4.0, "B", 1), (6.0, "A", 0)] {
			buffer.store(OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: now.addingTimeInterval(minutesAhead * 60)))
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let store = makeStore(refresher: refresher, now: { now }, coordinator: OAuthTokenCoordinator())

			let accessToken = try await store.accessToken()

			XCTAssertEqual(expectedAccessToken, accessToken, "\(minutesAhead) minutes ahead")
			XCTAssertEqual(expectedCallCount, refresher.callCount, "\(minutesAhead) minutes ahead")
		}
	}

	func testFailedRefreshBeforeExpiryReturnsCurrentTokenAndThrowsAfterExpiry() async throws {
		let now = Date()
		for (minutesAhead, throwsError) in [(4.0, false), (-1.0, true)] {
			buffer.store(OAuthToken(accessToken: "A", refreshToken: "RA", expiresAt: now.addingTimeInterval(minutesAhead * 60)))
			let refresher = RefresherMock { _ in throw URLError(.timedOut) }
			let store = makeStore(refresher: refresher, now: { now }, coordinator: OAuthTokenCoordinator())

			do {
				let accessToken = try await store.accessToken()
				XCTAssertFalse(throwsError, "\(minutesAhead) minutes ahead")
				XCTAssertEqual("A", accessToken)
			} catch {
				XCTAssertTrue(throwsError, "\(minutesAhead) minutes ahead")
				XCTAssertEqual(.timedOut, (error as? URLError)?.code)
			}
		}
	}

	// MARK: - Failures

	func testCancelledCallerDoesNotCancelSharedRefresh() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let gate = Gate()
		let refresher = RefresherMock(gate: gate) { _ in OAuthTokenStoreTests.tokenB }
		let storage = MemoryTokenStorage(buffer: buffer)
		let store = makeStore(storage: storage, refresher: refresher)

		let cancelledCaller = Task {
			try await store.refresh(rejecting: "A")
		}
		await fulfillment(of: [refresher.entered], timeout: testWaitTimeout)
		let otherCaller = Task {
			try await store.refresh(rejecting: "A")
		}
		cancelledCaller.cancel()
		gate.open()

		let accessToken = try await value(of: otherCaller)
		_ = try? await value(of: cancelledCaller)
		XCTAssertEqual("B", accessToken)
		XCTAssertEqual(1, storage.saveCount)
		XCTAssertEqual(OAuthTokenStoreTests.tokenB, buffer.token)
	}

	func testRefresherErrorReachesAllWaitersAndNextCallRefreshesAgain() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let gate = Gate()
		let refresher = RefresherMock(gate: gate) { callCount in
			guard callCount > 1 else {
				throw URLError(.timedOut)
			}
			return OAuthTokenStoreTests.tokenB
		}
		let storage = MemoryTokenStorage(buffer: buffer)
		let store = makeStore(storage: storage, refresher: refresher)
		let callersStarted = XCTestExpectation(description: "callers started")
		callersStarted.expectedFulfillmentCount = 2

		let callers = (0 ..< 2).map { _ in
			Task { @MainActor in
				callersStarted.fulfill()
				return try await store.refresh(rejecting: "A")
			}
		}
		await fulfillment(of: [callersStarted, refresher.entered], timeout: testWaitTimeout)
		await MainActor.run {
			gate.open()
		}
		for caller in callers {
			await XCTAssertThrowsErrorAsync(try await value(of: caller)) { error in
				XCTAssertEqual(.timedOut, (error as? URLError)?.code)
			}
		}
		XCTAssertEqual(0, storage.saveCount)

		let accessToken = try await store.refresh(rejecting: "A")

		XCTAssertEqual("B", accessToken)
		XCTAssertEqual(2, refresher.callCount)
	}

	func testRejectedRefreshDeletesNothing() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let store = makeStore(refresher: RefresherMock { _ in throw CloudProviderError.unauthorized })

		await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "A")) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		XCTAssertEqual(OAuthTokenStoreTests.tokenA, buffer.token)
	}

	func testMissingStoredTokenThrowsUnauthorizedWithoutRefresh() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let store = makeStore(refresher: refresher)
		_ = try await store.accessToken()
		buffer.data = nil

		await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "A")) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		await XCTAssertThrowsErrorAsync(try await store.accessToken()) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		XCTAssertEqual(0, refresher.callCount)
	}

	func testUnsavedTokenIsSavedBeforeNextRefresh() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let storage = MemoryTokenStorage(buffer: buffer)
		storage.failsSaves = true
		let store = makeStore(storage: storage, refresher: refresher)

		let rotatedAccessToken = try await store.refresh(rejecting: "A")
		let currentAccessToken = try await store.accessToken()

		XCTAssertEqual("B", rotatedAccessToken)
		XCTAssertEqual("B", currentAccessToken)
		XCTAssertEqual(OAuthTokenStoreTests.tokenA, buffer.token)

		storage.failsSaves = false
		let accessToken = try await store.refresh(rejecting: "A")

		XCTAssertEqual("B", accessToken)
		XCTAssertEqual(1, refresher.callCount)
		XCTAssertEqual(OAuthTokenStoreTests.tokenB, buffer.token)
	}

	func testUnsavedTokenDoesNotRestoreDeletedOrReplacedLogin() async throws {
		for replacesLogin in [false, true] {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
			let storage = MemoryTokenStorage(buffer: buffer)
			storage.failsSaves = true
			let store = makeStore(storage: storage, refresher: refresher, coordinator: OAuthTokenCoordinator())
			let otherProcessStore = makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenC }, coordinator: OAuthTokenCoordinator())
			_ = try await store.refresh(rejecting: "A")
			storage.failsSaves = false

			if replacesLogin {
				try await otherProcessStore.replace(with: OAuthTokenStoreTests.tokenC)
				let accessToken = try await store.refresh(rejecting: "B")
				XCTAssertEqual("C", accessToken)
				XCTAssertEqual(OAuthTokenStoreTests.tokenC, buffer.token)
			} else {
				try await otherProcessStore.delete(revoking: { _ in })
				await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "B")) { error in
					XCTAssertEqual(.unauthorized, error as? CloudProviderError)
				}
				XCTAssertNil(buffer.data)
			}
			XCTAssertEqual(1, refresher.callCount)
		}
	}

	func testDeleteRevokesUnsavedToken() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let storage = MemoryTokenStorage(buffer: buffer)
		storage.failsSaves = true
		let store = makeStore(storage: storage, refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })
		_ = try await store.refresh(rejecting: "A")
		let revokedTokens = OSAllocatedUnfairLock(initialState: [OAuthToken]())

		try await store.delete(revoking: { token in
			revokedTokens.withLock { $0.append(token) }
		})

		XCTAssertEqual([OAuthTokenStoreTests.tokenB], revokedTokens.withLock { $0 })
		XCTAssertNil(buffer.data)
	}

	// MARK: - Execution Assertion

	func testRefreshWithoutExecutionTimeThrowsWithoutRequest() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let store = makeStore(refresher: refresher, script: ActivityScript(refusesAssertions: true))

		let callers = (0 ..< 2).map { _ in
			Task {
				try await store.refresh(rejecting: "A")
			}
		}

		for caller in callers {
			await XCTAssertThrowsErrorAsync(try await value(of: caller)) { error in
				XCTAssertEqual(.executionTimeUnavailable, error as? OAuthTokenStoreError)
			}
		}
		XCTAssertEqual(0, refresher.callCount)
	}

	func testExpiryWhileWaitingForLockThrowsWithoutRequest() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let script = ActivityScript()
		let contention = XCTestExpectation(description: "refresh waits for the lock")
		contention.assertForOverFulfill = false
		let store = makeStore(refresher: refresher, script: script, lockEvents: CrossProcessFileLock.Events(contention: { contention.fulfill() }))
		let otherHolder = try await store.makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))

		let refresh = Task {
			try await store.refresh(rejecting: "A")
		}
		await fulfillment(of: [contention], timeout: testWaitTimeout)
		script.expireRunningAssertion()
		otherHolder.release()

		await XCTAssertThrowsErrorAsync(try await value(of: refresh)) { error in
			XCTAssertEqual(.executionTimeUnavailable, error as? OAuthTokenStoreError)
		}
		XCTAssertEqual(0, refresher.callCount)
	}

	func testExpiryWhileLoadingStoredTokenThrowsWithoutRequest() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let script = ActivityScript()
		let storage = MemoryTokenStorage(buffer: buffer, onLoad: { script.expireRunningAssertion() })
		let store = makeStore(storage: storage, refresher: refresher, script: script)

		await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "A")) { error in
			XCTAssertEqual(.executionTimeUnavailable, error as? OAuthTokenStoreError)
		}
		XCTAssertEqual(0, refresher.callCount)
	}

	func testExpiryWhileLoadingUnsavedTokensSourceKeepsItUnsaved() async throws {
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
		let store = makeStore(storage: storage, refresher: refresher, script: script)
		_ = try await store.refresh(rejecting: "A")
		storage.failsSaves = false
		expiresOnLoad.withLock { $0 = true }

		await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "A")) { error in
			XCTAssertEqual(.executionTimeUnavailable, error as? OAuthTokenStoreError)
		}
		XCTAssertEqual(OAuthTokenStoreTests.tokenA, buffer.token)

		expiresOnLoad.withLock { $0 = false }
		let accessToken = try await store.refresh(rejecting: "A")

		XCTAssertEqual("B", accessToken)
		XCTAssertEqual(OAuthTokenStoreTests.tokenB, buffer.token)
		XCTAssertEqual(1, refresher.callCount)
	}

	func testExpiryWhileDeletingKeepsItemWithoutRevocation() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let script = ActivityScript()
		let storage = MemoryTokenStorage(buffer: buffer, onLoad: { script.expireRunningAssertion() })
		let store = makeStore(storage: storage, refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, script: script)
		let revocationCount = OSAllocatedUnfairLock(initialState: 0)

		await XCTAssertThrowsErrorAsync(try await store.delete(revoking: { _ in
			revocationCount.withLock { $0 += 1 }
		})) { error in
			XCTAssertEqual(.executionTimeUnavailable, error as? OAuthTokenStoreError)
		}
		XCTAssertEqual(0, revocationCount.withLock { $0 })
		XCTAssertEqual(OAuthTokenStoreTests.tokenA, buffer.token)
	}

	func testExpiryDuringStorageWriteReleasesLockAfterWrite() async throws {
		for write in ["save", "delete"] {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let script = ActivityScript()
			let writeStarted = XCTestExpectation(description: "write started")
			let writeGate = DispatchSemaphore(value: 0)
			let storage = MemoryTokenStorage(buffer: buffer, onWrite: {
				writeStarted.fulfill()
				_ = writeGate.wait(timeout: .now() + testWaitTimeout)
			})
			let store = makeStore(storage: storage, refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, script: script)
			let operation = Task {
				if write == "save" {
					try await store.replace(with: OAuthTokenStoreTests.tokenC)
				} else {
					try await store.delete(revoking: { _ in })
				}
			}
			await fulfillment(of: [writeStarted], timeout: testWaitTimeout)
			let expiryStarted = XCTestExpectation(description: "expiry started")
			let expiryReturned = XCTestExpectation(description: "expiry returned")
			// The expiry waits for the write, so it runs on another thread.
			DispatchQueue.global().async {
				expiryStarted.fulfill()
				script.expireRunningAssertion()
				expiryReturned.fulfill()
			}
			await fulfillment(of: [expiryStarted], timeout: testWaitTimeout)

			await XCTAssertThrowsErrorAsync(try await store.makeLock().acquire(timeout: .milliseconds(500), pollInterval: .milliseconds(10)), write) { error in
				XCTAssertEqual(.lockTimeout, error as? OAuthTokenStoreError, write)
			}
			writeGate.signal()
			try await value(of: operation)
			await fulfillment(of: [expiryReturned], timeout: testWaitTimeout)
			let otherHolder = try await store.makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
			otherHolder.release()

			XCTAssertEqual(write == "save" ? OAuthTokenStoreTests.tokenC : nil, buffer.token, write)
		}
	}

	func testDeleteReleasesLockBeforeRevoking() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let store = makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, coordinator: OAuthTokenCoordinator())
		let otherProcessStore = makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB }, coordinator: OAuthTokenCoordinator())
		let gate = Gate()
		let revocationStarted = XCTestExpectation(description: "revocation started")

		let delete = Task {
			try await store.delete(revoking: { _ in
				revocationStarted.fulfill()
				await gate.wait()
			})
		}
		await fulfillment(of: [revocationStarted], timeout: testWaitTimeout)
		try await value(of: Task {
			try await otherProcessStore.replace(with: OAuthTokenStoreTests.tokenC)
		})
		gate.open()

		try await value(of: delete)
		XCTAssertEqual(OAuthTokenStoreTests.tokenC, buffer.token)
	}

	func testExpiryDuringRefreshReleasesLockAndLateResponseIsSavedOnlyOverItsSource() async throws {
		for meanwhile in ["nothing", "delete", "replace"] {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let lateRefresh = try await startLateRefresh(storage: MemoryTokenStorage(buffer: buffer), script: ActivityScript())
			lateRefresh.otherHolder.release()
			let otherProcessStore = makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenC }, coordinator: OAuthTokenCoordinator())
			if meanwhile == "delete" {
				try await otherProcessStore.delete(revoking: { _ in })
			} else if meanwhile == "replace" {
				try await otherProcessStore.replace(with: OAuthTokenStoreTests.tokenC)
			}
			lateRefresh.gate.open()

			if meanwhile == "delete" {
				await XCTAssertThrowsErrorAsync(try await value(of: lateRefresh.refresh)) { error in
					XCTAssertEqual(.unauthorized, error as? CloudProviderError)
				}
				XCTAssertNil(buffer.data)
			} else {
				let expectedToken = meanwhile == "replace" ? OAuthTokenStoreTests.tokenC : OAuthTokenStoreTests.tokenB
				let accessToken = try await value(of: lateRefresh.refresh)
				let currentAccessToken = try await lateRefresh.store.accessToken()
				XCTAssertEqual(expectedToken.accessToken, accessToken, meanwhile)
				XCTAssertEqual(expectedToken.accessToken, currentAccessToken, meanwhile)
				XCTAssertEqual(expectedToken, buffer.token, meanwhile)
			}
		}
	}

	func testLateResponseThatCannotBeSavedNowIsSavedBeforeNextRefresh() async throws {
		for failure in ["assertion refused", "lock timeout", "load failure", "expiry while loading"] {
			buffer.store(OAuthTokenStoreTests.tokenA)
			let script = ActivityScript()
			let expiresOnLoad = OSAllocatedUnfairLock(initialState: false)
			let storage = MemoryTokenStorage(buffer: buffer, onLoad: {
				if expiresOnLoad.withLock({ $0 }) {
					script.expireRunningAssertion()
				}
			})
			let lateRefresh = try await startLateRefresh(storage: storage, script: script, lockTimeout: failure == "lock timeout" ? .milliseconds(100) : .seconds(testWaitTimeout))
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
			lateRefresh.gate.open()

			let accessToken = try await value(of: lateRefresh.refresh)

			XCTAssertEqual("B", accessToken, failure)
			XCTAssertEqual(OAuthTokenStoreTests.tokenA, buffer.token, failure)

			lateRefresh.otherHolder.release()
			script.refusesAssertions = false
			storage.failsLoads = false
			expiresOnLoad.withLock { $0 = false }
			let savedAccessToken = try await lateRefresh.store.refresh(rejecting: "A")

			XCTAssertEqual("B", savedAccessToken, failure)
			XCTAssertEqual(OAuthTokenStoreTests.tokenB, buffer.token, failure)
			XCTAssertEqual(1, lateRefresh.refresher.callCount, failure)
		}
	}

	// MARK: - Lock Timeout

	func testLockTimeoutReturnsChangedStoredTokenAndOtherwiseThrows() async throws {
		buffer.store(OAuthTokenStoreTests.tokenB)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenC }
		let store = makeStore(refresher: refresher, lockTimeout: .milliseconds(100))
		let otherHolder = try await store.makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
		defer {
			otherHolder.release()
		}

		let accessToken = try await store.refresh(rejecting: "A")

		XCTAssertEqual("B", accessToken)
		await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "B")) { error in
			XCTAssertEqual(.lockTimeout, error as? OAuthTokenStoreError)
		}
		XCTAssertEqual(0, refresher.callCount)
	}

	func testLockTimeoutWithUnsavedTokenThrowsAndKeepsIt() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let refresher = RefresherMock { _ in OAuthTokenStoreTests.tokenB }
		let storage = MemoryTokenStorage(buffer: buffer)
		storage.failsSaves = true
		let store = makeStore(storage: storage, refresher: refresher, lockTimeout: .milliseconds(100))
		_ = try await store.refresh(rejecting: "A")
		storage.failsSaves = false
		let otherHolder = try await store.makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))

		await XCTAssertThrowsErrorAsync(try await store.refresh(rejecting: "B")) { error in
			XCTAssertEqual(.lockTimeout, error as? OAuthTokenStoreError)
		}
		otherHolder.release()
		let accessToken = try await store.refresh(rejecting: "A")

		XCTAssertEqual("B", accessToken)
		XCTAssertEqual(OAuthTokenStoreTests.tokenB, buffer.token)
		XCTAssertEqual(1, refresher.callCount)
	}

	// MARK: - Delete

	func testDeleteDeletesAlsoIfRevocationFails() async throws {
		buffer.store(OAuthTokenStoreTests.tokenA)
		let store = makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })

		await XCTAssertThrowsErrorAsync(try await store.delete(revoking: { _ in throw URLError(.timedOut) })) { error in
			XCTAssertEqual(.timedOut, (error as? URLError)?.code)
		}
		XCTAssertNil(buffer.data)
	}

	func testDeleteOfMissingOrUndecodableItemSkipsRevocation() async throws {
		for storedData in [nil, Data("garbage".utf8)] {
			buffer.data = storedData
			let store = makeStore(refresher: RefresherMock { _ in OAuthTokenStoreTests.tokenB })
			let revocationCount = OSAllocatedUnfairLock(initialState: 0)

			try await store.delete(revoking: { _ in
				revocationCount.withLock { $0 += 1 }
			})

			XCTAssertEqual(0, revocationCount.withLock { $0 })
			XCTAssertNil(buffer.data)
		}
	}

	// MARK: - Helpers

	private struct LateRefresh {
		let store: OAuthTokenStore
		let refresher: RefresherMock
		let gate: Gate
		let refresh: Task<String, Error>
		/// Holds the lock that the refresh released when its assertion expired.
		let otherHolder: CrossProcessFileLock.Holder
	}

	/// Starts a refresh of token A to token B whose assertion expires while the refresher waits for the gate, and returns once another holder acquired the released lock.
	private func startLateRefresh(storage: MemoryTokenStorage, script: ActivityScript, lockTimeout: Duration = .seconds(testWaitTimeout)) async throws -> LateRefresh {
		let gate = Gate()
		let refresher = RefresherMock(gate: gate) { _ in OAuthTokenStoreTests.tokenB }
		let store = makeStore(storage: storage, refresher: refresher, script: script, lockTimeout: lockTimeout, coordinator: OAuthTokenCoordinator())
		let refresh = Task {
			try await store.refresh(rejecting: "A")
		}
		await fulfillment(of: [refresher.entered], timeout: testWaitTimeout)
		script.expireRunningAssertion()
		let otherHolder = try await value(of: Task {
			try await store.makeLock().acquire(timeout: .seconds(testWaitTimeout), pollInterval: .milliseconds(10))
		})
		return LateRefresh(store: store, refresher: refresher, gate: gate, refresh: refresh, otherHolder: otherHolder)
	}

	private func makeStore(storage: MemoryTokenStorage? = nil, refresher: RefresherMock, script: ActivityScript = ActivityScript(), now: @escaping @Sendable () -> Date = Date.init, lockTimeout: Duration = .seconds(testWaitTimeout), lockEvents: CrossProcessFileLock.Events = .init(), coordinator: OAuthTokenCoordinator = OAuthTokenCoordinator()) -> OAuthTokenStore {
		return OAuthTokenStore(provider: "test", account: "user", storage: storage ?? MemoryTokenStorage(buffer: buffer), lockDirectory: lockDirectoryURL, legacyDecoder: BoxLegacyToken.decode, refresher: { try await refresher.refresh($0) }, assertion: script.assertion, now: now, lockTimeout: lockTimeout, lockPollInterval: .milliseconds(10), lockEvents: lockEvents, coordinator: coordinator)
	}
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

final class MemoryTokenStorage: OAuthTokenStorage {
	private struct State {
		var loadCount = 0
		var saveCount = 0
		var failsLoads = false
		var failsSaves = false
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

	var failsLoads: Bool {
		get { state.withLock { $0.failsLoads } }
		set { state.withLock { $0.failsLoads = newValue } }
	}

	var failsSaves: Bool {
		get { state.withLock { $0.failsSaves } }
		set { state.withLock { $0.failsSaves = newValue } }
	}

	func load(forAccount account: String) throws -> Data? {
		let failsLoads = state.withLock { state in
			state.loadCount += 1
			return state.failsLoads
		}
		onLoad()
		guard !failsLoads else {
			throw CocoaError(.fileReadUnknown)
		}
		return buffer.data
	}

	func save(_ data: Data, forAccount account: String) throws {
		try state.withLock { state in
			guard !state.failsSaves else {
				throw CocoaError(.fileWriteUnknown)
			}
			state.saveCount += 1
		}
		onWrite()
		buffer.data = data
	}

	func delete(forAccount account: String) throws {
		onWrite()
		buffer.data = nil
	}
}

/// Records the tokens of the refreshes and, if it has a gate, holds each back until the gate opens.
final class RefresherMock: Sendable {
	let entered = XCTestExpectation(description: "refresher entered")
	private let gate: Gate?
	private let result: @Sendable (_ callCount: Int) throws -> OAuthToken
	private let receivedTokens = OSAllocatedUnfairLock(initialState: [OAuthToken]())

	init(gate: Gate? = nil, result: @escaping @Sendable (_ callCount: Int) throws -> OAuthToken) {
		self.gate = gate
		self.result = result
		entered.assertForOverFulfill = false
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
		await gate?.wait()
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

final class Gate: Sendable {
	private let state = OSAllocatedUnfairLock(initialState: (isOpen: false, waiters: [CheckedContinuation<Void, Never>]()))

	func wait() async {
		await withCheckedContinuation { continuation in
			let isOpen = state.withLock { state in
				if !state.isOpen {
					state.waiters.append(continuation)
				}
				return state.isOpen
			}
			if isOpen {
				continuation.resume()
			}
		}
	}

	func open() {
		let waiters = state.withLock { state in
			state.isOpen = true
			defer { state.waiters = [] }
			return state.waiters
		}
		for waiter in waiters {
			waiter.resume()
		}
	}
}
