//
//  OneDriveCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 23.12.24.
//

public class OneDriveCredential: MicrosoftGraphCredential {
	override public class var scopes: [String] {
		return ["https://graph.microsoft.com/Files.ReadWrite"]
	}
}
