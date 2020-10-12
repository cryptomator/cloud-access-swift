//
//  URLSession+Promises.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 03.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

public enum URLSessionError: Error {
	case httpError(_ error: Error?, statusCode: Int)
	case unexpectedResponse
}

extension URLSession {
	func performDataTask(with request: URLRequest) -> Promise<(HTTPURLResponse, Data?)> {
		return Promise { fulfill, reject in
			let task = self.dataTask(with: request) { data, response, error in
				switch (response, error) {
				case let (httpResponse as HTTPURLResponse, nil):
					fulfill((httpResponse, data))
				case let (httpResponse as HTTPURLResponse, .some(error)):
					reject(URLSessionError.httpError(error, statusCode: httpResponse.statusCode))
				case let (_, .some(error)):
					reject(error)
				default:
					reject(URLSessionError.unexpectedResponse)
				}
			}
			task.resume()
		}
	}

	func performDownloadTask(with request: URLRequest) -> Promise<(HTTPURLResponse, URL?)> {
		return Promise { fulfill, reject in
			let task = self.downloadTask(with: request) { url, response, error in
				switch (response, error) {
				case let (httpResponse as HTTPURLResponse, nil):
					fulfill((httpResponse, url))
				case let (httpResponse as HTTPURLResponse, .some(error)):
					reject(URLSessionError.httpError(error, statusCode: httpResponse.statusCode))
				case let (_, .some(error)):
					reject(error)
				default:
					reject(URLSessionError.unexpectedResponse)
				}
			}
			task.resume()
		}
	}

	func performUploadTask(with request: URLRequest, fromFile fileURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		return Promise { fulfill, reject in
			let task = self.uploadTask(with: request, fromFile: fileURL) { data, response, error in
				switch (response, error) {
				case let (httpResponse as HTTPURLResponse, nil):
					fulfill((httpResponse, data))
				case let (httpResponse as HTTPURLResponse, .some(error)):
					reject(URLSessionError.httpError(error, statusCode: httpResponse.statusCode))
				case let (_, .some(error)):
					reject(error)
				default:
					reject(URLSessionError.unexpectedResponse)
				}
			}
			task.resume()
		}
	}
}
