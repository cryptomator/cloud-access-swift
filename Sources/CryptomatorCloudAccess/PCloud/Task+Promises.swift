//
//  Task+Promises.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 25.02.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import PCloudSDKSwift
import Promises

extension CallTask {
	func execute() -> Promise<Method.Value> {
		return Promise<Method.Value> { fulfill, reject in
			self.addCompletionBlock { result in
				switch result {
				case let .success(value):
					fulfill(value)
				case let .failure(error):
					switch error {
					case .authError, .otherAPIError:
						reject(CloudProviderError.unauthorized)
					default:
						reject(error)
					}
				}
			}
			self.start()
		}
	}
}

extension DownloadTask {
	func execute() -> Promise<URL> {
		return Promise<URL> { fulfill, reject in
			self.addCompletionBlock { result in
				switch result {
				case let .success(url):
					fulfill(url)
				case let .failure(error):
					reject(error)
				}
			}
			self.start()
		}
	}
}

extension UploadTask {
	func execute() -> Promise<Method.Value> {
		return Promise<Method.Value> { fulfill, reject in
			self.addCompletionBlock { result in
				switch result {
				case let .success(value):
					fulfill(value)
				case let .failure(error):
					switch error {
					case .authError, .otherAPIError:
						reject(CloudProviderError.unauthorized)
					default:
						reject(error)
					}
				}
			}
			self.start()
		}
	}
}
