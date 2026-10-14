//
//  CloudProvider+CreateIntermediateFolders.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Philipp Schmid on 12.10.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import Foundation

extension CloudProvider {
	func createFolderWithIntermediates(for cloudPath: CloudPath) async throws {
		guard cloudPath != CloudPath("/") else {
			return
		}
		var path = CloudPath("/")
		let pathComponents = cloudPath.pathComponents.dropFirst()
		for component in pathComponents {
			path = path.appendingPathComponent(component)
			try await createFolderIfMissing(at: path)
		}
	}
}
