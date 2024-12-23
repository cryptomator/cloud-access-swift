//
//  SharePointCredential.swift
//  CryptomatorCloudAccess
//
//  Created by Majid Achhoud on 23.12.24.
//

public class SharePointCredential: MicrosoftGraphCredential {
	override public class var scopes: [String] {
		return ["https://graph.microsoft.com/Sites.Read.All"]
	}
}
