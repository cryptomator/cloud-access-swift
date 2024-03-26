//
//  BoxAuthenticator.swift
//
//
//  Created by Majid Achhoud on 18.03.24.
//

import Foundation
import BoxSDK
import Promises
import UIKit

public enum BoxAuthenticatorError: Error {
    case authenticationFailed
}

public struct BoxAuthenticator {
    
    private static let sdk = BoxSDK(clientId: BoxSetup.constants.clientId, clientSecret: BoxSetup.constants.clientSecret)
    
    public static func authenticate(from viewController: UIViewController) -> Promise<BoxClient> {
        return Promise { fulfill, reject in
            sdk.getOAuth2Client() { result in
                switch result {
                case let .success(client):
                    fulfill(client)
                case .failure(_):
                    reject(BoxAuthenticatorError.authenticationFailed)
                }
            }
        }
    }
}
