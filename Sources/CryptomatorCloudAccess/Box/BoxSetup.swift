//
//  BoxSetup.swift
//
//
//  Created by Majid Achhoud on 18.03.24.
//

import Foundation

public class BoxSetup {
	public static var constants: BoxSetup!

	public let clientId: String
	public let clientSecret: String
	public let sharedContainerIdentifier: String?

	public init(clientId: String, clientSecret: String, sharedContainerIdentifier: String?) {
		self.clientId = clientId
		self.clientSecret = clientSecret
		self.sharedContainerIdentifier = sharedContainerIdentifier
	}
}
