//
//  CallTask+Async.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 25.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
@preconcurrency import PCloudSDKSwift

extension CallTask where Method.Value: Sendable {
	func execute() async throws -> Method.Value {
		return try await withSDKContinuation { resumer in
			addCompletionBlock { result in
				resumer.resume(with: result.mapError(convertCallError))
			}
			start()
		}
	}
}

extension DownloadTask {
	func execute() async throws -> URL {
		return try await withSDKContinuation { resumer in
			addCompletionBlock { result in
				resumer.resume(with: result.mapError(convertNetworkOperationError))
			}
			start()
		}
	}
}

extension UploadTask where Method.Value: Sendable {
	func execute() async throws -> Method.Value {
		return try await withSDKContinuation { resumer in
			addCompletionBlock { result in
				resumer.resume(with: result.mapError(convertCallError))
			}
			start()
		}
	}
}

func convertCallError(_ error: CallError<some Any>) -> Error {
	switch error {
	case .authError, .otherAPIError:
		return CloudProviderError.unauthorized
	case let .clientError(underlyingError) where isCancellationError(underlyingError):
		return CancellationError()
	case let .clientError(underlyingError) where isNetworkConnectionError(underlyingError):
		return CloudProviderError.noInternetConnection
	default:
		return error
	}
}

func convertNetworkOperationError(_ error: NetworkOperationError) -> Error {
	switch error {
	case let .clientError(underlyingError) where isCancellationError(underlyingError):
		return CancellationError()
	case let .clientError(underlyingError) where isNetworkConnectionError(underlyingError):
		return CloudProviderError.noInternetConnection
	default:
		return error
	}
}
