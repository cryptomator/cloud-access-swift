//
//  SharePointCloudProvider.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 02.12.24.
//

import Foundation
import MSGraphClientSDK
import Promises

/// Specialized cloud provider for SharePoint operations.
/// Inherits all functionalities from MicrosoftGraphCloudProvider.
public class SharePointCloudProvider: MicrosoftGraphCloudProvider {
	private let sharePointDiscovery: SharePointDiscovery
	private let driveID: String

	 init(credential: SharePointCredential, driveID: String, maxPageSize: Int) throws {
		self.driveID = driveID
		
		guard credential.authProvider is MicrosoftGraphAuthenticationProvider else {
			throw MicrosoftGraphError.invalidAuthProvider
		}

		self.sharePointDiscovery = SharePointDiscovery(credential: credential)
		try super.init(credential: credential, maxPageSize: maxPageSize, urlSessionConfiguration: .default, unauthenticatedURLSessionConfiguration: .default)
	}

	// MARK: - Overriding URL handling for SharePoint-specific logic

	/// Constructs URL for SharePoint items based on the provided MicrosoftGraphItem
	override func requestURLString(for item: MicrosoftGraphItem) -> String {
		return "\(MSGraphBaseURL)/sites/\(driveID)/items/\(item.identifier)"
	}
}
