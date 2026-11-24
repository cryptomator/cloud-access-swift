//
//  LoggedOperation.swift
//  CryptomatorCloudAccessCore
//
//  Created by Tobias Hagemann on 20.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/**
 Logs the operation, runs it and converts the error that it throws. The failure log shows the error before the conversion.

 - Parameter logPrefix: The name of the provider that the log lines start with.
 */
func performLogged<T>(_ operation: String, by logPrefix: String, convert: (Error) -> Error, describe: (Error) -> String = { "\($0)" }, _ body: () async throws -> T) async throws -> T {
	CloudAccessDDLogDebug("\(logPrefix): \(operation) called")
	do {
		return try await body()
	} catch {
		CloudAccessDDLogDebug("\(logPrefix): \(operation) failed with error: \(describe(error))")
		throw convert(error)
	}
}
