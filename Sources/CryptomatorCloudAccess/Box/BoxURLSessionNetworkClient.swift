//
//  BoxURLSessionNetworkClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import Foundation
import os

private struct BoxTaskResult {
	let response: HTTPURLResponse
	let data: Data
	/// The destination of a download whose body was moved there.
	let downloadDestinationURL: URL?
}

private struct BoxRunningTask {
	let resumer: Resumer<BoxTaskResult>
	let downloadDestinationURL: URL?
	var accumulatedData = Data()
	var isDownloadMoved = false
	var failure: Error?

	/// Moves the body of a 2xx download to its destination. Any other body becomes the response data instead, so that an error response never ends up at the destination.
	mutating func finishDownload(from location: URL, response: URLResponse?) {
		guard let downloadDestinationURL else {
			return
		}
		do {
			if let httpResponse = response as? HTTPURLResponse, (200 ... 299).contains(httpResponse.statusCode) {
				try? FileManager.default.removeItem(at: downloadDestinationURL)
				try FileManager.default.moveItem(at: location, to: downloadDestinationURL)
				isDownloadMoved = true
			} else {
				accumulatedData = try Data(contentsOf: location)
			}
		} catch {
			failure = error
		}
	}

	func complete(with response: URLResponse?, error: Error?) {
		let movedDownloadURL = isDownloadMoved ? downloadDestinationURL : nil
		if let httpResponse = response as? HTTPURLResponse {
			HTTPDebugLogger.logResponse(httpResponse, with: accumulatedData, or: movedDownloadURL)
		}
		if let failure {
			resumer.resume(throwing: failure)
		} else if let error {
			resumer.resume(throwing: error)
		} else if let httpResponse = response as? HTTPURLResponse {
			resumer.resume(returning: BoxTaskResult(response: httpResponse, data: accumulatedData, downloadDestinationURL: movedDownloadURL))
		} else {
			resumer.resume(throwing: URLError(.badServerResponse))
		}
	}
}

private final class BoxURLSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, Sendable {
	private let runningTasks = OSAllocatedUnfairLock(initialState: [URLSessionTask: BoxRunningTask]())

	func addRunningTask(key: URLSessionTask, value: BoxRunningTask) {
		runningTasks.withLock {
			$0[key] = value
		}
	}

	// MARK: - URLSessionTaskDelegate

	func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
		let runningTask = runningTasks.withLock {
			$0.removeValue(forKey: task)
		}
		runningTask?.complete(with: task.response, error: error)
	}

	// MARK: - URLSessionDataDelegate

	func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
		runningTasks.withLock {
			$0[dataTask]?.accumulatedData.append(data)
		}
	}

	// MARK: - URLSessionDownloadDelegate

	func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
		let response = downloadTask.response
		runningTasks.withLock {
			$0[downloadTask]?.finishDownload(from: location, response: response)
		}
	}
}

/**
 Network client of the Box SDK that also works with a background `URLSession`.

 Downloads and uploads run on a session with the given configuration, as download and upload tasks. Uploads are sent from a file, which is the only kind of upload a background session supports. Other requests run as data tasks on a foreground session, because a background session doesn't support them.

 Task cancellation is not forwarded to a request, so a request returns only after its `URLSessionTask` has terminated. Cancellation only cuts short the delay before a retry. Redirects are always followed, and transport errors are not retried.
 */
final class BoxURLSessionNetworkClient: NetworkClient, Sendable {
	private struct BodyFile {
		let url: URL
		let contentType: String?
	}

	private static let bufferLength = 64 * 1024

	private let transferSession: URLSession
	private let metadataSession: URLSession
	private let delegate: BoxURLSessionDelegate

	init(configuration: URLSessionConfiguration) {
		let delegate = BoxURLSessionDelegate()
		self.delegate = delegate
		self.transferSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
		if configuration.identifier != nil {
			self.metadataSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
		} else {
			self.metadataSession = transferSession
		}
	}

	deinit {
		transferSession.invalidateAndCancel()
		if metadataSession !== transferSession {
			metadataSession.invalidateAndCancel()
		}
	}

	func fetch(options: FetchOptions) async throws -> FetchResponse {
		let networkSession = options.networkSession ?? NetworkSession(networkClient: self)
		// The body file is written once, because the streams that the SDK passes can only be read once.
		let bodyFile = try createBodyFile(for: options)
		defer {
			if let bodyFile {
				try? FileManager.default.removeItem(at: bodyFile.url)
			}
		}
		var attemptNumber = 1
		while true {
			let request = try await createRequest(for: options, networkSession: networkSession, bodyFile: bodyFile)
			let result: BoxTaskResult
			do {
				result = try await perform(request, for: options, bodyFile: bodyFile)
			} catch let error as URLError {
				throw BoxNetworkError(message: error.localizedDescription, error: error)
			}
			let httpResponse = result.response
			let response = createFetchResponse(for: result, options: options)
			if try await networkSession.retryStrategy.shouldRetry(fetchOptions: options, fetchResponse: response, attemptNumber: attemptNumber) {
				// The retry strategy has refreshed the token of an unauthorized request, so it is retried right away.
				if httpResponse.statusCode != 401 {
					let delay = networkSession.retryStrategy.retryAfter(fetchOptions: options, fetchResponse: response, attemptNumber: attemptNumber)
					try await _Concurrency.Task.sleep(for: .seconds(delay))
				}
				attemptNumber += 1
				continue
			}
			guard (200 ..< 400).contains(httpResponse.statusCode) else {
				throw createAPIError(httpResponse, data: result.data, for: request, options: options, networkSession: networkSession)
			}
			return response
		}
	}

	// MARK: - Request

	private func createRequest(for options: FetchOptions, networkSession: NetworkSession, bodyFile: BodyFile?) async throws -> URLRequest {
		var request = try URLRequest(url: createEndpointURL(url: options.url, params: options.params))
		request.httpMethod = options.method.uppercased()
		request.allHTTPHeaderFields = options.headers
		for (key, value) in networkSession.additionalHeaders {
			request.setValue(value, forHTTPHeaderField: key)
		}
		request.setValue(bodyFile?.contentType ?? options.contentType, forHTTPHeaderField: "Content-Type")
		if options.multipartData != nil {
			request.setValue("application/json", forHTTPHeaderField: "Accept")
		}
		for (key, value) in BoxConstants.analyticsHeaders {
			request.setValue(value, forHTTPHeaderField: key)
		}
		if let auth = options.auth {
			try await request.setValue(auth.retrieveAuthorizationHeader(networkSession: networkSession), forHTTPHeaderField: "Authorization")
		}
		if let data = options.data {
			if options.contentType == "application/x-www-form-urlencoded" {
				request.httpBody = try Data(Utils.Url.urlEncodedFrom(data: data.data).utf8)
			} else {
				request.httpBody = data.data
			}
		}
		return request
	}

	private func createEndpointURL(url: String, params: [String: String]?) throws -> URL {
		guard var components = URLComponents(string: url) else {
			throw BoxSDKError(message: "Invalid URL: \(url)")
		}
		if let params {
			components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
			// `URLComponents` leaves a plus sign unencoded, which the server would read as a space.
			components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
		}
		guard let endpointURL = components.url else {
			throw BoxSDKError(message: "Invalid URL: \(url)")
		}
		return endpointURL
	}

	private func perform(_ request: URLRequest, for options: FetchOptions, bodyFile: BodyFile?) async throws -> BoxTaskResult {
		HTTPDebugLogger.logRequest(request)
		let task: URLSessionTask
		let downloadDestinationURL: URL?
		if let destinationURL = options.downloadDestinationUrl, options.responseFormat == .binary {
			task = transferSession.downloadTask(with: request)
			downloadDestinationURL = destinationURL
		} else if let bodyFile {
			task = transferSession.uploadTask(with: request, fromFile: bodyFile.url)
			downloadDestinationURL = nil
		} else {
			task = metadataSession.dataTask(with: request)
			downloadDestinationURL = nil
		}
		return try await withSDKContinuation { resumer in
			delegate.addRunningTask(key: task, value: BoxRunningTask(resumer: resumer, downloadDestinationURL: downloadDestinationURL))
			task.resume()
		}
	}

	// MARK: - Body File

	private func createBodyFile(for options: FetchOptions) throws -> BodyFile? {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: false)
		if let multipartData = options.multipartData {
			let boundary = "Boundary-\(UUID().uuidString)"
			try writeMultipartBody(multipartData, boundary: boundary, to: url)
			return BodyFile(url: url, contentType: "multipart/form-data; boundary=\(boundary)")
		} else if let fileStream = options.fileStream {
			try writeFile(to: url) { fileHandle in
				try write(fileStream, to: fileHandle)
			}
			return BodyFile(url: url, contentType: nil)
		} else {
			return nil
		}
	}

	private func writeMultipartBody(_ multipartData: [MultipartItem], boundary: String, to url: URL) throws {
		try writeFile(to: url) { fileHandle in
			for part in multipartData {
				if let data = part.data {
					try fileHandle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.partName)\"\r\n\r\n".utf8))
					try fileHandle.write(contentsOf: data.data)
				} else if let fileStream = part.fileStream {
					try fileHandle.write(contentsOf: Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.partName)\"; filename=\"\(part.fileName ?? "")\"\r\nContent-Type: \(part.contentType ?? "application/octet-stream")\r\n\r\n".utf8))
					try write(fileStream, to: fileHandle)
				} else {
					continue
				}
				try fileHandle.write(contentsOf: Data("\r\n".utf8))
			}
			try fileHandle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
		}
	}

	private func writeFile(to url: URL, _ body: (FileHandle) throws -> Void) throws {
		guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
			throw BoxSDKError(message: "Could not create a body file at \(url)")
		}
		do {
			let fileHandle = try FileHandle(forWritingTo: url)
			defer {
				try? fileHandle.close()
			}
			try body(fileHandle)
		} catch {
			try? FileManager.default.removeItem(at: url)
			throw error
		}
	}

	private func write(_ inputStream: InputStream, to fileHandle: FileHandle) throws {
		inputStream.open()
		defer {
			inputStream.close()
		}
		var buffer = [UInt8](repeating: 0, count: BoxURLSessionNetworkClient.bufferLength)
		while true {
			let readCount = inputStream.read(&buffer, maxLength: buffer.count)
			if readCount < 0 {
				throw inputStream.streamError ?? BoxSDKError(message: "Could not read the body stream")
			} else if readCount == 0 {
				return
			}
			try fileHandle.write(contentsOf: buffer[0 ..< readCount])
		}
	}

	// MARK: - Response

	private func createFetchResponse(for result: BoxTaskResult, options: FetchOptions) -> FetchResponse {
		let headers = createHeaders(result.response)
		if let downloadDestinationURL = result.downloadDestinationURL {
			return FetchResponse(status: result.response.statusCode, headers: headers, url: options.url, downloadDestinationUrl: downloadDestinationURL)
		} else {
			return FetchResponse(status: result.response.statusCode, headers: headers, url: options.url, data: SerializedData(data: result.data))
		}
	}

	private func createAPIError(_ httpResponse: HTTPURLResponse, data: Data, for request: URLRequest, options: FetchOptions, networkSession: NetworkSession) -> BoxAPIError {
		let requestInfo = RequestInfo(method: options.method.uppercased(), url: options.url, queryParams: options.params ?? [:], headers: request.allHTTPHeaderFields ?? [:], contentType: options.contentType)
		let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		let responseInfo = ResponseInfo(
			statusCode: httpResponse.statusCode,
			headers: createHeaders(httpResponse),
			body: SerializedData(data: data),
			rawBody: Utils.Strings.from(data: data),
			code: json?["code"] as? String,
			contextInfo: json?["context_info"] as? [String: Any],
			requestId: json?["request_id"] as? String,
			helperUrl: json?["help_url"] as? String,
			message: json?["message"] as? String
		)
		let message = "The API returned an unexpected response: [\(httpResponse.statusCode)] \(responseInfo.code ?? "") \(responseInfo.message ?? "")"
		return BoxAPIError(message: message, requestInfo: requestInfo, responseInfo: responseInfo, dataSanitizer: networkSession.dataSanitizer)
	}

	private func createHeaders(_ httpResponse: HTTPURLResponse) -> [String: String] {
		return httpResponse.allHeaderFields.reduce(into: [:]) { headers, field in
			if let key = field.key as? String, let value = field.value as? String {
				headers[key] = value
			}
		}
	}
}
