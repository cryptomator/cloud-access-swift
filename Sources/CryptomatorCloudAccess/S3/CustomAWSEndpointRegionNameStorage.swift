//
//  CustomAWSEndpointRegionNameStorage.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 20.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation

class CustomAWSEndpointRegionNameStorage {
	static let shared = CustomAWSEndpointRegionNameStorage()
	private let queue = DispatchQueue(label: "CustomAWSEndpointRegionNameStorage", attributes: .concurrent)
	private var regionNames = [String: String]()

	func getRegionName(for hostName: String) -> String? {
		return queue.sync {
			regionNames[hostName]
		}
	}

	func setRegionName(_ regionName: String, for hostName: String) {
		return queue.sync {
			print("setRegionName: \(regionName) for hostName: \(hostName)")
			regionNames[hostName] = regionName
		}
	}

	func setRegionName(_ regionName: String, for url: URL) {
		guard let hostName = url.host else {
			return
		}
		setRegionName(regionName, for: hostName)
	}
}

extension CustomAWSEndpointRegionNameStorage {
	func setRegionName(_ regionName: String, for credential: S3Credential) {
		setRegionName(regionName, for: credential.url)
		if let host = credential.url.host {
			setRegionName(regionName, for: "\(credential.bucket).\(host)")
		}
	}
}
