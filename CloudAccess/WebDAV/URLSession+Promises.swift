//
//  URLSession+Promises.swift
//  CloudAccess
//
//  Created by Tobias Hagemann on 03.07.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Promises

enum URLSessionError: Error {
	case httpError(_ error: Error, response: HTTPURLResponse)
	case unexpectedResponse
}

extension URLSession {
	func performDataTask(with request: URLRequest) -> Promise<(HTTPURLResponse, Data?)> {
		return Promise { fulfill, reject in
			let task = self.dataTask(with: request) { data, response, error in
				guard let httpResponse = response as? HTTPURLResponse else {
					reject(URLSessionError.unexpectedResponse)
					return
				}
				if let error = error {
					reject(URLSessionError.httpError(error, response: httpResponse))
				} else {
					fulfill((httpResponse, data))
				}
			}
			task.resume()
		}
	}

	func performDownloadTask(with request: URLRequest) -> Promise<(HTTPURLResponse, URL?)> {
		return Promise { fulfill, reject in
			let task = self.downloadTask(with: request) { url, response, error in
				guard let httpResponse = response as? HTTPURLResponse else {
					reject(URLSessionError.unexpectedResponse)
					return
				}
				if let error = error {
					reject(URLSessionError.httpError(error, response: httpResponse))
				} else {
					fulfill((httpResponse, url))
				}
			}
			task.resume()
		}
	}

	func performUploadTask(with request: URLRequest, fromFile fileURL: URL) -> Promise<(HTTPURLResponse, Data?)> {
		return Promise { fulfill, reject in
			let task = self.uploadTask(with: request, fromFile: fileURL) { data, response, error in
				guard let httpResponse = response as? HTTPURLResponse else {
					reject(URLSessionError.unexpectedResponse)
					return
				}
				if let error = error {
					reject(URLSessionError.httpError(error, response: httpResponse))
				} else {
					fulfill((httpResponse, data))
				}
			}
			task.resume()
		}
	}
}
