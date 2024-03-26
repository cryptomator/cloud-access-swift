//
//  BoxCredential.swift
//
//
//  Created by Majid Achhoud on 19.03.24.
//

import Foundation
import BoxSDK

public class BoxCredential {
    
    public var client: BoxClient
    
    public init() {
        self.client = BoxSDK.getClient(token: "m9DKTNlQovcvIgxRIPMaxLdjwQVDxq1g")
    }
}
