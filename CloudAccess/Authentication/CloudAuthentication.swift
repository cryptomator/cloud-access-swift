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
    
    func getUsername() -> Promise<String>
    
    func deauthenticate() -> Promise<Void>
    
}
