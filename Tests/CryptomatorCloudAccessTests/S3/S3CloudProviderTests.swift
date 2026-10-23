//
//  S3CloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 01.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import os
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3CloudProviderTests: XCTestCase {
	var provider: S3CloudProvider!
	var tmpDirURL: URL!

	override func setUpWithError() throws {
		provider = try S3CloudProvider(client: .mocked(), maxPageSize: .max)
		tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
		try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		URLProtocolMock.requestHandler = []
		try FileManager.default.removeItem(at: tmpDirURL)
	}

	func testThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(provider)
	}

	func testCheckContinuationTokenForInvalidityWithCancelledRequest() async {
		let error = await provider.checkContinuationTokenForInvalidity(continuationToken: "token", folderPath: .root, error: CancellationError())
		XCTAssertTrue(error is CancellationError)
	}

	func testGetPrefix() {
		let rootCloudPath = CloudPath("/")
		XCTAssertEqual("", provider.getPrefix(for: rootCloudPath))

		XCTAssertEqual("foo/", provider.getPrefix(for: CloudPath("/foo")))
		XCTAssertEqual("foo/", provider.getPrefix(for: CloudPath("/foo/")))

		XCTAssertEqual("foo/bar/", provider.getPrefix(for: CloudPath("/foo/bar")))
	}

	func testGetKey() {
		XCTAssertEqual("foo.txt", provider.getKey(for: CloudPath("/foo.txt")))
		XCTAssertEqual("foo/bar.txt", provider.getKey(for: CloudPath("/foo/bar.txt")))
	}

	// MARK: - Error Conversion

	func testConvertStandardErrorPassesCancellationThrough() {
		XCTAssertTrue(provider.convertStandardError(CancellationError()) is CancellationError)
	}

	func testConvertUnauthorizedErrors() {
		for code in ["AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidSignatureException", "AuthFailure", "AccessDeniedException", "AuthMissingFailure", "InvalidClientTokenId", "MissingAuthenticationToken"] {
			XCTAssertEqual(.unauthorized, provider.convertStandardError(S3Error(statusCode: 403, code: code)) as? CloudProviderError, code)
		}
		XCTAssertEqual(.unauthorized, provider.convertStandardError(S3Error(statusCode: 401)) as? CloudProviderError)
		XCTAssertEqual(.unauthorized, provider.convertStandardError(S3Error(statusCode: 403)) as? CloudProviderError)
		XCTAssertEqual(.unauthorized, provider.convertStandardError(NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue))) as? CloudProviderError)
	}

	func testConvertInvalidPageTokenErrors() {
		for code in ["ExpiredToken", "InvalidToken", "TokenRefreshRequired"] {
			XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(S3Error(statusCode: 400, code: code)) as? CloudProviderError, code)
		}
		XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "continuation-token")) as? CloudProviderError)
		XCTAssertEqual(.pageTokenInvalid, provider.convertStandardError(S3Error(statusCode: 500, code: "InternalError", reason: "Incorrect padding")) as? CloudProviderError)
	}

	func testConvertItemNotFoundError() {
		XCTAssertEqual(.itemNotFound, provider.convertStandardError(S3Error(statusCode: 404, code: "NoSuchKey")) as? CloudProviderError)
	}

	func testConvertNoInternetConnectionError() {
		XCTAssertEqual(.noInternetConnection, provider.convertStandardError(URLError(.notConnectedToInternet)) as? CloudProviderError)
	}

	func testConvertOtherErrorsUnchanged() {
		XCTAssertEqual(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "max-keys"), provider.convertStandardError(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "max-keys")) as? S3Error)
		XCTAssertEqual(S3Error(statusCode: 404, code: "NoSuchBucket"), provider.convertStandardError(S3Error(statusCode: 404, code: "NoSuchBucket")) as? S3Error)
		XCTAssertEqual(S3Error(statusCode: 404), provider.convertStandardError(S3Error(statusCode: 404)) as? S3Error)
	}

	// MARK: - Transfers

	func testDownloadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: S3CloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		let progress = Progress(totalUnitCount: 1)
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"])),
			URLProtocolMock.handler(body: "content", onRequest: { _ in
				XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			})
		]

		let metadata = try await value(of: Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: progress, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(Data("content".utf8), try Data(contentsOf: localURL))
		XCTAssertEqual(7, metadata.size)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
		let provider: S3CloudProvider = provider
		let localURL = try makeLocalFile()
		let progress = Progress(totalUnitCount: 1)
		let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
		let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			URLProtocolMock.handler(onRequest: { _ in
				XCTAssertTrue(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
			}),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"]), onRequest: { _ in
				XCTAssertGreaterThan(progress.fractionCompleted, 0.5, "The progress of the upload task isn't part of the upload's progress")
				XCTAssertLessThan(progress.fractionCompleted, 1, "The progress completed before the upload returned")
			})
		]

		let metadata = try await value(of: Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: { task in
				taskStates.withLock { $0.append(task.state) }
				try? await Task.sleep(for: .milliseconds(100))
				onTaskCreationReturned.withLock { $0 = true }
			})
		})

		XCTAssertEqual([.suspended], taskStates.withLock { $0 })
		XCTAssertEqual(CloudPath("/file.txt"), metadata.cloudPath)
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDownloadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: S3CloudProvider = provider
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"])),
			URLProtocolMock.handler(body: "content")
		]

		let download = Task {
			try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: download)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled download must not be resumed")
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	func testUploadFileWithCancellationDuringOnTaskCreation() async throws {
		let provider: S3CloudProvider = provider
		let localURL = try makeLocalFile()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			URLProtocolMock.handler()
		]

		let upload = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				withUnsafeCurrentTask { $0?.cancel() }
			})
		}
		await XCTAssertThrowsErrorAsync(try await value(of: upload)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}

		XCTAssertEqual(1, URLProtocolMock.requestHandler.count, "The task of a cancelled upload must not be resumed")
	}

	/// The error body of a download may be missing, so any 404 means that the file is gone.
	func testDownloadFileOfMissingFileThrowsItemNotFound() async throws {
		let localURL = tmpDirURL.appendingPathComponent("file.txt")
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"])),
			URLProtocolMock.handler(statusCode: 404)
		]

		await XCTAssertThrowsErrorAsync(try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: localURL.path))
	}

	/// The upload committed with its PUT, so a cancellation afterwards must not cut short the retries of the metadata request.
	func testUploadFileCancelledAfterPutReturnsMetadata() async throws {
		let provider: S3CloudProvider = provider
		let localURL = try makeLocalFile()
		let upload = OSAllocatedUnfairLock<Task<CloudItemMetadata, Error>?>(initialState: nil)
		let uploadStored = DispatchSemaphore(value: 0)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: { _ in
				_ = uploadStored.wait(timeout: .now() + testWaitTimeout)
			}),
			URLProtocolMock.handler(onRequest: { _ in
				upload.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(statusCode: 503),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.txt"]))
		]

		let uploadTask = Task {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		}
		upload.withLock { $0 = uploadTask }
		uploadStored.signal()
		let metadata = try await value(of: uploadTask)

		XCTAssertEqual(CloudPath("/file.txt"), metadata.cloudPath)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Multipart Uploads

	func testUploadFileOverThresholdUploadsPartsInOrder() async throws {
		let progress = Progress(totalUnitCount: 1)
		let fractions = OSAllocatedUnfairLock(initialState: [Double]())
		let provider = try makeMultipartProvider(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions))
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let requests = RequestRecorder()
		let onTaskCreationCalled = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: requests.record),
			S3CloudProviderTests.initiateMultipartUpload(requests),
			S3CloudProviderTests.part(1, requests),
			S3CloudProviderTests.part(2, requests),
			S3CloudProviderTests.part(3, requests),
			S3CloudProviderTests.completeMultipartUpload(requests),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10), onRequest: requests.record)
		]

		let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: progress, onTaskCreation: { _ in
			onTaskCreationCalled.withLock { $0 = true }
		})

		XCTAssertEqual(10, metadata.size)
		let sent = requests.requests
		XCTAssertEqual(["GET", "POST", "PUT", "PUT", "PUT", "POST", "GET"], sent.map(\.httpMethod))
		XCTAssertEqual(["uploads": ""], S3CloudProviderTests.queryParameters(of: sent[1]))
		XCTAssertEqual("application/octet-stream", sent[1].value(forHTTPHeaderField: "Content-Type"))
		for (index, request) in sent[2 ... 4].enumerated() {
			let query = S3CloudProviderTests.queryParameters(of: request)
			XCTAssertEqual(String(index + 1), query["partNumber"])
			XCTAssertEqual("upload-id", query["uploadId"])
		}
		XCTAssertEqual(["0123", "4567", "89"], sent[2 ... 4].map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) })
		XCTAssertEqual(["uploadId": "upload-id"], S3CloudProviderTests.queryParameters(of: sent[5]))
		let completionBody = String(bytes: sent[5].httpBody ?? Data(), encoding: .utf8) ?? ""
		XCTAssertTrue(completionBody.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag></Part><Part><PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag></Part><Part><PartNumber>3</PartNumber><ETag>&quot;etag-3&quot;</ETag></Part></CompleteMultipartUpload>"), completionBody)
		XCTAssertFalse(onTaskCreationCalled.withLock { $0 }, "A task that uploads only a part was passed to onTaskCreation")
		let recordedFractions = fractions.withLock { $0 }
		XCTAssertEqual(3, recordedFractions.count)
		for (index, (fraction, (bytesBefore, partLength))) in zip(recordedFractions, [(0.0, 4.0), (4.0, 4.0), (8.0, 2.0)]).enumerated() {
			XCTAssertGreaterThan(fraction, (bytesBefore + partLength / 2) / 10, "part \(index)")
			XCTAssertLessThan(fraction, 1, "part \(index)")
		}
		XCTAssertEqual(1, progress.fractionCompleted)
		XCTAssertEqual(temporaryFiles, try uuidNamedTemporaryFiles())
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileAtThresholdUsesSinglePut() async throws {
		let provider = try makeMultipartProvider(multipartUploadThreshold: 10)
		let requests = RequestRecorder()
		let onTaskCreationCalled = OSAllocatedUnfairLock(initialState: false)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []), onRequest: requests.record),
			URLProtocolMock.handler(onRequest: requests.record),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10), onRequest: requests.record)
		]

		_ = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
			onTaskCreationCalled.withLock { $0 = true }
		})

		let sent = requests.requests
		XCTAssertEqual(["GET", "PUT", "GET"], sent.map(\.httpMethod))
		XCTAssertNil(S3CloudProviderTests.queryParameters(of: sent[1])["uploadId"])
		XCTAssertEqual(Data("0123456789".utf8), sent[1].httpBody)
		XCTAssertTrue(onTaskCreationCalled.withLock { $0 })
	}

	/// The size of a symbolic link's target counts, not the link's own.
	func testUploadFileThroughSymbolicLinkUsesSizeOfTarget() async throws {
		let provider = try makeMultipartProvider()
		let linkURL = tmpDirURL.appendingPathComponent("link.bin")
		try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: makeLocalFile(content: "0123456789"))
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			S3CloudProviderTests.initiateMultipartUpload(),
			S3CloudProviderTests.part(1, requests),
			S3CloudProviderTests.part(2, requests),
			S3CloudProviderTests.part(3, requests),
			S3CloudProviderTests.completeMultipartUpload(),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10))
		]

		_ = try await provider.uploadFile(from: linkURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)

		XCTAssertEqual(["0123", "4567", "89"], requests.requests.map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) })
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testFailedPartAbortsMultipartUpload() async throws {
		let provider = try makeMultipartProvider()
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			S3CloudProviderTests.initiateMultipartUpload(),
			URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>"),
			S3CloudProviderTests.abortMultipartUpload(requests)
		]

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.unauthorized, error as? CloudProviderError)
		}
		try assertAborted(requests, temporaryFiles: temporaryFiles)
	}

	/// S3 refuses a completion whose parts don't match the uploaded ones, after which the multipart upload would stay pending.
	func testFailedCompletionAbortsMultipartUpload() async throws {
		let provider = try makeMultipartProvider()
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			S3CloudProviderTests.initiateMultipartUpload(),
			S3CloudProviderTests.part(1),
			S3CloudProviderTests.part(2),
			S3CloudProviderTests.part(3),
			URLProtocolMock.handler(statusCode: 400, body: "<Error><Code>InvalidPart</Code></Error>"),
			S3CloudProviderTests.abortMultipartUpload(requests)
		]

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual("InvalidPart", (error as? S3Error)?.code)
		}
		try assertAborted(requests, temporaryFiles: temporaryFiles)
	}

	/// A file that got shorter during the upload must not complete as a shorter object, also when only its last part is short. A failed abort doesn't replace that error.
	func testFileThatGetsShorterDuringMultipartUploadAborts() async throws {
		let provider = try makeMultipartProvider()
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			S3CloudProviderTests.initiateMultipartUpload(),
			S3CloudProviderTests.part(1),
			URLProtocolMock.handler(headerFields: ["ETag": "\"etag-2\""], onRequest: { _ in
				try? FileHandle(forWritingTo: localURL).truncate(atOffset: 9)
			}),
			URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>", onRequest: requests.record)
		]

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.fileReadCorruptFile, (error as? CocoaError)?.code)
		}
		try assertAborted(requests, temporaryFiles: temporaryFiles)
	}

	func testUnreadableFileAbortsMultipartUpload() async throws {
		let provider = try makeMultipartProvider()
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			URLProtocolMock.handler(body: S3MockResponse.initiateMultipartUploadResult(), onRequest: { _ in
				try? FileManager.default.removeItem(at: localURL)
			}),
			S3CloudProviderTests.abortMultipartUpload(requests)
		]

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.fileNoSuchFile, (error as? CocoaError)?.code)
		}
		try assertAborted(requests, temporaryFiles: temporaryFiles)
	}

	/// The abort of a cancelled upload is retried after a transient failure, so that no multipart upload is left behind.
	func testCancellationDuringPartAbortsMultipartUpload() async throws {
		let provider = try makeMultipartProvider()
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let canceller = TaskCanceller<CloudItemMetadata>()
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			S3CloudProviderTests.initiateMultipartUpload(),
			URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""], onRequest: { _ in
				canceller.cancel()
			}),
			URLProtocolMock.handler(statusCode: 503, onRequest: requests.record),
			S3CloudProviderTests.abortMultipartUpload(requests)
		]

		await XCTAssertThrowsErrorAsync(try await value(of: canceller.start {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		try assertAborted(requests, attempts: 2, temporaryFiles: temporaryFiles)
	}

	/// The last part leaves no check in the loop, so the check before the completion stops the upload.
	func testCancellationDuringLastPartAbortsMultipartUpload() async throws {
		let provider = try makeMultipartProvider()
		let localURL = try makeLocalFile(content: "0123456789")
		let temporaryFiles = try uuidNamedTemporaryFiles()
		let canceller = TaskCanceller<CloudItemMetadata>()
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			S3CloudProviderTests.initiateMultipartUpload(),
			S3CloudProviderTests.part(1),
			S3CloudProviderTests.part(2),
			URLProtocolMock.handler(headerFields: ["ETag": "\"etag-3\""], onRequest: { _ in
				canceller.cancel()
			}),
			S3CloudProviderTests.abortMultipartUpload(requests)
		]

		await XCTAssertThrowsErrorAsync(try await value(of: canceller.start {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		})) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		try assertAborted(requests, temporaryFiles: temporaryFiles)
	}

	/// The completion commits the upload, so a cancellation during it must not cut short its retries or abort the upload.
	func testCancellationDuringCompletionCompletesUpload() async throws {
		let provider = try makeMultipartProvider()
		let localURL = try makeLocalFile(content: "0123456789")
		let canceller = TaskCanceller<CloudItemMetadata>()
		let requests = RequestRecorder()
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			S3CloudProviderTests.initiateMultipartUpload(),
			S3CloudProviderTests.part(1),
			S3CloudProviderTests.part(2),
			S3CloudProviderTests.part(3),
			URLProtocolMock.handler(statusCode: 503, onRequest: { request in
				requests.record(request)
				canceller.cancel()
			}),
			S3CloudProviderTests.completeMultipartUpload(requests),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10), onRequest: requests.record)
		]

		let metadata = try await value(of: canceller.start {
			try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)
		})

		XCTAssertEqual(CloudPath("/file.bin"), metadata.cloudPath)
		XCTAssertEqual(["POST", "POST", "GET"], requests.requests.map(\.httpMethod))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testUploadFileOverMaximumSizeThrowsBeforeAnyRequest() async throws {
		let provider = try makeMultipartProvider(maxPartCount: 1)
		let localURL = tmpDirURL.appendingPathComponent("sparse.bin")
		XCTAssertTrue(FileManager.default.createFile(atPath: localURL.path, contents: nil))
		try FileHandle(forWritingTo: localURL).truncate(atOffset: UInt64(S3Client.maxPartSize + 1))
		URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))]

		await XCTAssertThrowsErrorAsync(try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)) { error in
			XCTAssertEqual(.dataLengthExceedsMaximum, (error as? URLError)?.code)
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testPartSize() {
		let mebibyte = 1024 * 1024
		XCTAssertEqual(32 * mebibyte, S3CloudProvider.partSize(forFileSize: 4768 * mebibyte + 1, minPartSize: 32 * mebibyte, maxPartCount: 1000))
		XCTAssertEqual(41 * mebibyte, S3CloudProvider.partSize(forFileSize: 1000 * 40 * mebibyte + 1, minPartSize: 32 * mebibyte, maxPartCount: 1000))
		XCTAssertEqual(S3Client.maxPartSize, S3CloudProvider.partSize(forFileSize: 1000 * S3Client.maxPartSize, minPartSize: 32 * mebibyte, maxPartCount: 1000))
		XCTAssertEqual(S3Client.maxPartSize + mebibyte, S3CloudProvider.partSize(forFileSize: 1000 * S3Client.maxPartSize + 1, minPartSize: 32 * mebibyte, maxPartCount: 1000))
	}

	// MARK: - Requests

	func testFetchItemListRequestsOnePageOfFolder() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], commonPrefixes: ["folder/sub/"], nextContinuationToken: "next"), onRequest: { request in
				requests.withLock { $0.append(request) }
			})
		]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: "token")

		let request = try XCTUnwrap(requests.withLock { $0 }.first)
		XCTAssertEqual("GET", request.httpMethod)
		XCTAssertEqual("/exampleBucket", request.url?.path)
		XCTAssertEqual(["list-type": "2", "prefix": "folder/", "max-keys": "1001", "delimiter": "/", "continuation-token": "token"], S3CloudProviderTests.queryParameters(of: request))
		XCTAssertEqual([CloudPath("/folder/a.txt"), CloudPath("/folder/sub")], itemList.items.map(\.cloudPath))
		XCTAssertEqual([.file, .folder], itemList.items.map(\.itemType))
		XCTAssertEqual("next", itemList.nextPageToken)
	}

	func testFetchItemListParsesLastModified() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], lastModified: "2026-10-18T12:34:56.500Z"))
		]

		let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)

		XCTAssertEqual([Date(timeIntervalSince1970: 1_792_326_896.5)], itemList.items.map(\.lastModifiedDate))
	}

	func testFetchItemMetadataOfFolderListedAfterSibling() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
		let recordRequest: @Sendable (URLRequest) -> Void = { request in
			requests.withLock { $0.append(request) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [], commonPrefixes: ["folder 2/"], nextContinuationToken: "next"), onRequest: recordRequest),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/"]), onRequest: recordRequest)
		]

		let metadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

		XCTAssertEqual(CloudPath("/folder"), metadata.cloudPath)
		XCTAssertEqual(.folder, metadata.itemType)
		XCTAssertEqual([
			["list-type": "2", "prefix": "folder", "max-keys": "1", "delimiter": "/"],
			["list-type": "2", "prefix": "folder/", "max-keys": "1", "delimiter": "/"]
		], requests.withLock { $0 }.map(S3CloudProviderTests.queryParameters(of:)))
	}

	func testFetchItemMetadataDoesNotListFolderAfterSiblingInCancelledTask() async throws {
		let provider: S3CloudProvider = provider
		let fetch = OSAllocatedUnfairLock<Task<CloudItemMetadata, Error>?>(initialState: nil)
		let fetchStored = DispatchSemaphore(value: 0)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [], commonPrefixes: ["folder 2/"], nextContinuationToken: "next"), onRequest: { _ in
				_ = fetchStored.wait(timeout: .now() + testWaitTimeout)
				fetch.withLock { $0 }?.cancel()
			}),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/"]))
		]

		let fetchTask = Task {
			try await provider.fetchItemMetadata(at: CloudPath("/folder"))
		}
		fetch.withLock { $0 = fetchTask }
		fetchStored.signal()

		await XCTAssertThrowsErrorAsync(try await value(of: fetchTask)) { error in
			XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
		}
		XCTAssertEqual(1, URLProtocolMock.requestHandler.count)
	}

	func testFetchItemMetadataThrowsItemNotFoundIfOnlySiblingExists() async throws {
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder.txt"], nextContinuationToken: "next")),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))
		]

		await XCTAssertThrowsErrorAsync(try await provider.fetchItemMetadata(at: CloudPath("/folder"))) { error in
			XCTAssertEqual(.itemNotFound, error as? CloudProviderError)
		}
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testCreateFolderPutsFolderMarker() async throws {
		let markerRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [])),
			URLProtocolMock.handler(onRequest: { request in
				markerRequest.withLock { $0 = request }
			})
		]

		try await provider.createFolder(at: CloudPath("/folder"))

		let request = try XCTUnwrap(markerRequest.withLock { $0 })
		XCTAssertEqual("PUT", request.httpMethod)
		XCTAssertEqual("/exampleBucket/folder/", request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath })
		XCTAssertEqual("application/x-directory", request.value(forHTTPHeaderField: "Content-Type"))
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	func testDeleteFolderDeletesEveryPage() async throws {
		let requests = OSAllocatedUnfairLock(initialState: [(request: URLRequest, body: String)]())
		let recordRequest: @Sendable (URLRequest) -> Void = { request in
			let body = String(bytes: URLProtocolMock.body(of: request), encoding: .utf8) ?? ""
			requests.withLock { $0.append((request, body)) }
		}
		URLProtocolMock.requestHandler = [
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/"])),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], nextContinuationToken: "next"), onRequest: recordRequest),
			URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: recordRequest),
			URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/b.txt"]), onRequest: recordRequest),
			URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: recordRequest)
		]

		try await provider.deleteFolder(at: CloudPath("/folder"))

		let sent = requests.withLock { $0 }
		XCTAssertEqual(["GET", "POST", "GET", "POST"], sent.map(\.request.httpMethod))
		XCTAssertEqual(["list-type": "2", "prefix": "folder/", "max-keys": "1000"], S3CloudProviderTests.queryParameters(of: sent[0].request))
		XCTAssertEqual(["list-type": "2", "prefix": "folder/", "max-keys": "1000", "continuation-token": "next"], S3CloudProviderTests.queryParameters(of: sent[2].request))
		XCTAssertEqual(["delete": ""], S3CloudProviderTests.queryParameters(of: sent[1].request))
		XCTAssertTrue(sent[1].body.contains("<Object><Key>folder/</Key></Object><Object><Key>folder/a.txt</Key></Object>"), sent[1].body)
		XCTAssertTrue(sent[3].body.contains("<Object><Key>folder/b.txt</Key></Object>"), sent[3].body)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty)
	}

	// MARK: - Helpers

	private static func queryParameters(of request: URLRequest) -> [String: String] {
		let queryItems = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
		return Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
	}

	/// With the default threshold, returns a provider that uploads a file of more than 9 bytes in parts of 4 bytes.
	private func makeMultipartProvider(multipartUploadThreshold: Int = 9, maxPartCount: Int = 1000, hooks: SplitURLSession.Hooks = SplitURLSession.Hooks()) throws -> S3CloudProvider {
		return try S3CloudProvider(client: .mocked(hooks: hooks), maxPageSize: .max, multipartUploadThreshold: multipartUploadThreshold, minPartSize: 4, maxPartCount: maxPartCount)
	}

	private static func initiateMultipartUpload(_ requests: RequestRecorder = RequestRecorder()) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return URLProtocolMock.handler(body: S3MockResponse.initiateMultipartUploadResult(), onRequest: requests.record)
	}

	private static func part(_ partNumber: Int, _ requests: RequestRecorder = RequestRecorder()) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return URLProtocolMock.handler(headerFields: ["ETag": "\"etag-\(partNumber)\""], onRequest: requests.record)
	}

	private static func completeMultipartUpload(_ requests: RequestRecorder = RequestRecorder()) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return URLProtocolMock.handler(body: S3MockResponse.completeMultipartUploadResult, onRequest: requests.record)
	}

	private static func abortMultipartUpload(_ requests: RequestRecorder) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
		return URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
	}

	/// Asserts that the recorded requests are the attempts to abort the multipart upload, that every queued response was used, and that the temporary files of the parts are gone.
	private func assertAborted(_ requests: RequestRecorder, attempts: Int = 1, temporaryFiles: Set<String>, file: StaticString = #filePath, line: UInt = #line) throws {
		let aborts = requests.requests
		XCTAssertEqual(Array(repeating: "DELETE", count: attempts), aborts.map(\.httpMethod), file: file, line: line)
		XCTAssertEqual(Array(repeating: ["uploadId": "upload-id"], count: attempts), aborts.map(S3CloudProviderTests.queryParameters(of:)), file: file, line: line)
		XCTAssertTrue(URLProtocolMock.requestHandler.isEmpty, file: file, line: line)
		XCTAssertEqual(temporaryFiles, try uuidNamedTemporaryFiles(), file: file, line: line)
	}

	private func makeLocalFile(content: String) throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent("local.bin")
		try Data(content.utf8).write(to: localURL)
		return localURL
	}

	private func makeLocalFile() throws -> URL {
		let localURL = tmpDirURL.appendingPathComponent("local.txt")
		try Data("content".utf8).write(to: localURL)
		return localURL
	}
}

extension S3Credential {
	static let stub = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://www.example.com")!, bucket: "exampleBucket", region: "example-region", identifier: UUID().uuidString)
}
