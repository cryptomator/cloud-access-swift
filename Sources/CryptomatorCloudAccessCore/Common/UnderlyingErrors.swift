//
//  UnderlyingErrors.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// The error, followed by each error that it wraps through `NSUnderlyingErrorKey`, because SDKs and Foundation wrap the errors that they report.
func underlyingErrorChain(of error: Error) -> some Sequence<Error> {
	return sequence(first: error) { ($0 as NSError).userInfo[NSUnderlyingErrorKey] as? Error }
}
