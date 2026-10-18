//
//  BoxURLSessionNetworkClient.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 14.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

@preconcurrency import BoxSdkGen
import Foundation

private struct BoxTaskResult {
	let response: HTTPURLResponse
	let data: Data
	/// The destination of a download whose body was moved there.
	let downloadDestinationURL: URL?
}

/**
 Network client of the Box SDK that also works with a background `URLSession`, see `SplitURLSession`.

 Cancellation only cuts short the delay before a retry. Redirects are always followed, and transport errors are not retried.
 */
final class BoxURLSessionNetworkClient: NetworkClient, Sendable {
	private struct BodyFile {
		let url: URL
		let contentType: String?
	}

	private static let bufferLength = 64 * 1024

	private let session: SplitURLSession

	init(configuration: URLSessionConfiguration) {
		self.session = SplitURLSession(configuration: configuration)
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
		if let destinationURL = options.downloadDestinationUrl, options.responseFormat == .binary {
			let (response, data) = try await session.download(request, to: destinationURL)
			return BoxTaskResult(response: response, data: data, downloadDestinationURL: (200 ... 299).contains(response.statusCode) ? destinationURL : nil)
		} else if let bodyFile {
			let (response, data) = try await session.upload(request, fromFile: bodyFile.url)
			return BoxTaskResult(response: response, data: data, downloadDestinationURL: nil)
		} else {
			let (response, data) = try await session.data(for: request, bodyLogging: containsCredentials(request) ? .omitted : .logged)
			return BoxTaskResult(response: response, data: data, downloadDestinationURL: nil)
		}
	}

	private func containsCredentials(_ request: URLRequest) -> Bool {
		guard let path = request.url?.path else {
			return false
		}
		return path.hasSuffix("/oauth2/token") || path.hasSuffix("/oauth2/revoke")
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
