//
//  AWSS3TransferUtility+ForegroundSession.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 30.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import AWSS3
import Foundation

extension AWSS3TransferUtility {
	private static let queue = DispatchQueue(label: "AWSS3TransferUtility-Swizzle")
	private static var sessions = [ObjectIdentifier: URLSession]()
	/// Contains the object identifiers of the AWSS3TransferUtilities which should use a foreground `URLSession`
	private static var foregroundUtilities = NSHashTable<AWSS3TransferUtility>(options: .weakMemory)

	static func useForegroundURLSession(for utility: AWSS3TransferUtility) {
		allowOptionalForegroundURLSession
		queue.sync {
			foregroundUtilities.add(utility)
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
		return AWSS3TransferUtility.queue.sync {
			guard AWSS3TransferUtility.foregroundUtilities.contains(self) else {
				print("called background URLSession")
				let originalBackgroundURLSession = self.foregroundURLSession
				return originalBackgroundURLSession
			}
			print("called foregroundURLSession")
			if let session = AWSS3TransferUtility.sessions[ObjectIdentifier(self)] {
				return session
			} else {
				let session = URLSession(configuration: .default, delegate: self as? URLSessionDelegate, delegateQueue: nil)
				AWSS3TransferUtility.sessions[ObjectIdentifier(self)] = session
				return session
			}
		}
	}
}
