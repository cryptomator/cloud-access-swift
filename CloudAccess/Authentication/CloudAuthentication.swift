//
//  CloudAuthentication.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 22.04.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises
import UIKit

public protocol CloudAuthentication {
    
    /**
     - Postcondition: Promise is rejected with CloudAuthenticationError.userCanceled if the user cancels the authentication.
     */
    func authenticate(from viewController: UIViewController) -> Promise<Void>
    
    func isAuthenticated() -> Promise<Bool>
    
    /**
     - Postcondition:
     Promise is rejected with CloudAuthenticationError.notAuthenticated if the user is not authenticated.
     
     Promise is rejected with CloudAuthenticationError.noUsername if the user is authenticated but there is no username.
     */
    func getUsername() -> Promise<String>
    
    func deauthenticate() -> Promise<Void>
    
}
