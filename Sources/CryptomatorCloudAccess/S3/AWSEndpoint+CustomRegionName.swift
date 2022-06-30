//
//  AWSEndpoint+CustomRegionName.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 15.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import AWSS3
import Foundation

extension AWSEndpoint {
	static let exchangeRegionNameImplementation: Void = {
		guard let originalMethod = class_getInstanceMethod(AWSEndpoint.self, Selector(("regionName"))), let swizzledMethod = class_getInstanceMethod(AWSEndpoint.self, #selector(getter: swizzledRegionName)) else {
			return
		}
		method_exchangeImplementations(originalMethod, swizzledMethod)

	}()

	@objc var swizzledRegionName: String {
		if let awsRegionName = AWSEndpoint.regionName(from: regionType) {
			return awsRegionName
		}
		return CustomAWSEndpointRegionNameStorage.shared.getRegionName(for: hostName) ?? ""
	}
}
