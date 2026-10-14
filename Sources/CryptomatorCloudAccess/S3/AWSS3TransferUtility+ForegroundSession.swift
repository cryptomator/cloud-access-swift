//
//  AWSS3TransferUtility+ForegroundSession.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 30.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

@preconcurrency import AWSS3
import Foundation
import os

extension AWSS3TransferUtility {
	private struct ForegroundSessionState {
		var sessions = [ObjectIdentifier: URLSession]()
		/// Contains the object identifiers of the AWSS3TransferUtilities which should use a foreground `URLSession`
		let foregroundUtilities = NSHashTable<AWSS3TransferUtility>(options: .weakMemory)
	}

	private static let state = OSAllocatedUnfairLock(uncheckedState: ForegroundSessionState())

	static func useForegroundURLSession(for utility: AWSS3TransferUtility) {
		allowOptionalForegroundURLSession
		state.withLockUnchecked {
			$0.foregroundUtilities.add(utility)
		}
	}

	private static let allowOptionalForegroundURLSession: Void = {
		guard let originalMethod = class_getInstanceMethod(AWSS3TransferUtility.self, Selector(("session"))), let swizzledMethod = class_getInstanceMethod(AWSS3TransferUtility.self, #selector(getter: foregroundURLSession)) else {
			print("failed to swizzle useForegroundURLSession")
			return
		}
		print("swizzled useForegroundURLSession")
		method_exchangeImplementations(originalMethod, swizzledMethod)
	}()

	@objc var foregroundURLSession: URLSession {
		return AWSS3TransferUtility.state.withLockUnchecked { state in
			guard state.foregroundUtilities.contains(self) else {
				print("called background URLSession")
				return self.foregroundURLSession
			}
			print("called foregroundURLSession")
			if let session = state.sessions[ObjectIdentifier(self)] {
				return session
			} else {
				let session = URLSession(configuration: .default, delegate: self as? URLSessionDelegate, delegateQueue: nil)
				state.sessions[ObjectIdentifier(self)] = session
				return session
			}
		}
	}
}
