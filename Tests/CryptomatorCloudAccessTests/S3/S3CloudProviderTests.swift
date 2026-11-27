//
//  S3CloudProviderTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Philipp Schmid on 01.06.22.
//  Copyright © 2022 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class S3CloudProviderTests {
		let provider: S3CloudProvider
		let tmpDirURL: URL

		init() throws {
			URLProtocolMock.requestHandler = []
			self.provider = try S3CloudProvider(client: .mocked(), maxPageSize: .max)
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		@Test
		func throwsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(provider)
		}

		@Test
		func checkContinuationTokenForInvalidityWithCancelledRequest() async {
			let error = await provider.checkContinuationTokenForInvalidity(continuationToken: "token", folderPath: .root, error: CancellationError())
			#expect(error is CancellationError)
		}

		/// No response is queued, so a probe of the folder below the root would fail with another error.
		@Test
		func checkContinuationTokenForInvalidityKeepsMissingConnection() async {
			for folderPath in [CloudPath.root, CloudPath("/foo")] {
				let error = await provider.checkContinuationTokenForInvalidity(continuationToken: "token", folderPath: folderPath, error: URLError(.notConnectedToInternet))
				#expect((error as? CloudProviderError) == .noInternetConnection, "\(folderPath.path)")
			}
		}

		@Test
		func checkContinuationTokenForInvalidityWithOtherErrorAtRoot() async {
			let error = await provider.checkContinuationTokenForInvalidity(continuationToken: "token", folderPath: .root, error: S3Error(statusCode: 500, code: "InternalError"))
			#expect((error as? CloudProviderError) == .pageTokenInvalid)
		}

		/// Only the listing's response is queued, so a probe of the folder below the root would fail with another error.
		@Test
		func fetchItemListWithPageTokenAndRejectedCredentialsThrowsUnauthorized() async throws {
			let provider: S3CloudProvider = provider
			for folderPath in [CloudPath.root, CloudPath("/foo")] {
				URLProtocolMock.requestHandler = [URLProtocolMock.handler(statusCode: 400, body: "<Error><Code>ExpiredToken</Code></Error>")]
				await #expect(throws: CloudProviderError.unauthorized, "\(folderPath.path)") { try await provider.fetchItemList(forFolderAt: folderPath, withPageToken: "token") }
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(folderPath.path)")
			}
		}

		@Test
		func testGetPrefix() {
			let rootCloudPath = CloudPath("/")
			#expect(provider.getPrefix(for: rootCloudPath) == "")

			#expect(provider.getPrefix(for: CloudPath("/foo")) == "foo/")
			#expect(provider.getPrefix(for: CloudPath("/foo/")) == "foo/")

			#expect(provider.getPrefix(for: CloudPath("/foo/bar")) == "foo/bar/")
		}

		@Test
		func testGetKey() {
			#expect(provider.getKey(for: CloudPath("/foo.txt")) == "foo.txt")
			#expect(provider.getKey(for: CloudPath("/foo/bar.txt")) == "foo/bar.txt")
			#expect(provider.getKey(for: CloudPath("/\u{301}foo.txt")) == "\u{301}foo.txt")
		}

		// MARK: - Error Conversion

		@Test
		func convertStandardErrorPassesCancellationThrough() {
			#expect(provider.convertStandardError(CancellationError()) is CancellationError)
		}

		@Test
		func convertUnauthorizedErrors() {
			for code in ["AccessDenied", "InvalidAccessKeyId", "SignatureDoesNotMatch", "InvalidSignatureException", "AuthFailure", "AccessDeniedException", "AuthMissingFailure", "InvalidClientTokenId", "MissingAuthenticationToken", "InvalidTokenId", "InvalidSecurity"] {
				#expect((provider.convertStandardError(S3Error(statusCode: 403, code: code)) as? CloudProviderError) == .unauthorized, "\(code)")
			}
			// These codes name a rejected security token, not a continuation token.
			for code in ["ExpiredToken", "InvalidToken", "TokenRefreshRequired"] {
				#expect((provider.convertStandardError(S3Error(statusCode: 400, code: code)) as? CloudProviderError) == .unauthorized, "\(code)")
			}
			#expect((provider.convertStandardError(S3Error(statusCode: 401, code: "Unauthorized")) as? CloudProviderError) == .unauthorized)
			#expect((provider.convertStandardError(S3Error(statusCode: 401)) as? CloudProviderError) == .unauthorized)
			#expect((provider.convertStandardError(S3Error(statusCode: 403)) as? CloudProviderError) == .unauthorized)
			#expect((provider.convertStandardError(NSError(domain: kCFErrorDomainCFNetwork as String, code: Int(CFNetworkErrors.cfErrorHTTPParseFailure.rawValue))) as? CloudProviderError) == .unauthorized)
		}

		@Test
		func convertInvalidPageTokenErrors() {
			#expect((provider.convertStandardError(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "continuation-token")) as? CloudProviderError) == .pageTokenInvalid)
			#expect((provider.convertStandardError(S3Error(statusCode: 500, code: "InternalError", reason: "Incorrect padding")) as? CloudProviderError) == .pageTokenInvalid)
		}

		@Test
		func convertItemNotFoundError() {
			#expect((provider.convertStandardError(S3Error(statusCode: 404, code: "NoSuchKey")) as? CloudProviderError) == .itemNotFound)
		}

		@Test
		func convertNoInternetConnectionError() {
			#expect((provider.convertStandardError(URLError(.notConnectedToInternet)) as? CloudProviderError) == .noInternetConnection)
		}

		@Test
		func convertOtherErrorsUnchanged() {
			#expect(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "max-keys") == (provider.convertStandardError(S3Error(statusCode: 400, code: "InvalidArgument", argumentName: "max-keys")) as? S3Error))
			#expect(S3Error(statusCode: 404, code: "NoSuchBucket") == (provider.convertStandardError(S3Error(statusCode: 404, code: "NoSuchBucket")) as? S3Error))
			#expect(S3Error(statusCode: 404) == (provider.convertStandardError(S3Error(statusCode: 404)) as? S3Error))
			#expect(S3Error(statusCode: 403, code: "Unauthorized") == (provider.convertStandardError(S3Error(statusCode: 403, code: "Unauthorized")) as? S3Error))
		}

		// MARK: - Transfers

		@Test
		func downloadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: S3CloudProvider = provider
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			let progress = Progress(totalUnitCount: 1)
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.txt", keys: ["file.txt"]),
				URLProtocolMock.handler(body: "content", onRequest: { _ in
					#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
				})
			]

			let metadata = try await cancellingValue(of: Task {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: progress, onTaskCreation: { task in
					taskStates.withLock { $0.append(task.state) }
					try? await Task.sleep(for: .milliseconds(100))
					onTaskCreationReturned.withLock { $0 = true }
				})
			})

			#expect(taskStates.withLock { $0 } == [.suspended])
			#expect(try Data("content".utf8) == Data(contentsOf: localURL))
			#expect(metadata.size == 7)
			#expect(progress.fractionCompleted == 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileAwaitsOnTaskCreationBeforeResumingTask() async throws {
			let provider: S3CloudProvider = provider
			let localURL = try makeLocalFile()
			let progress = Progress(totalUnitCount: 1)
			let taskStates = OSAllocatedUnfairLock(initialState: [URLSessionTask.State]())
			let onTaskCreationReturned = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.txt"),
				URLProtocolMock.handler(onRequest: { _ in
					#expect(onTaskCreationReturned.withLock { $0 }, "The task was resumed before onTaskCreation returned")
				}),
				S3CloudProviderTests.listing(of: "file.txt", keys: ["file.txt"], onRequest: { _ in
					#expect(progress.fractionCompleted > 0.5, "The progress of the upload task isn't part of the upload's progress")
					#expect(progress.fractionCompleted < 1, "The progress completed before the upload returned")
				})
			]

			let metadata = try await cancellingValue(of: Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: progress, onTaskCreation: { task in
					taskStates.withLock { $0.append(task.state) }
					try? await Task.sleep(for: .milliseconds(100))
					onTaskCreationReturned.withLock { $0 = true }
				})
			})

			#expect(taskStates.withLock { $0 } == [.suspended])
			#expect(CloudPath("/file.txt") == metadata.cloudPath)
			#expect(progress.fractionCompleted == 1)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func downloadFileWithCancellationDuringOnTaskCreation() async throws {
			let provider: S3CloudProvider = provider
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.txt", keys: ["file.txt"]),
				URLProtocolMock.handler(body: "content")
			]

			let download = Task {
				try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: { _ in
					withUnsafeCurrentTask { $0?.cancel() }
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: download) }

			#expect(URLProtocolMock.requestHandler.count == 1, "The task of a cancelled download must not be resumed")
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		@Test
		func uploadFileWithCancellationDuringOnTaskCreation() async throws {
			let provider: S3CloudProvider = provider
			let localURL = try makeLocalFile()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.txt"),
				URLProtocolMock.handler()
			]

			let upload = Task {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
					withUnsafeCurrentTask { $0?.cancel() }
				})
			}
			await #expect(throws: CancellationError.self) { try await cancellingValue(of: upload) }

			#expect(URLProtocolMock.requestHandler.count == 1, "The task of a cancelled upload must not be resumed")
		}

		/// The error body of a download may be missing, so any 404 means that the file is gone.
		@Test
		func downloadFileOfMissingFileThrowsItemNotFound() async throws {
			let localURL = tmpDirURL.appendingPathComponent("file.txt")
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.txt", keys: ["file.txt"]),
				URLProtocolMock.handler(statusCode: 404)
			]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.downloadFile(from: CloudPath("/file.txt"), to: localURL, progress: nil, onTaskCreation: nil) }
			#expect(!FileManager.default.fileExists(atPath: localURL.path))
		}

		/// The upload committed with its PUT, so a cancellation afterwards must not cut short the retries of the metadata request.
		@Test
		func uploadFileCancelledAfterPutReturnsMetadata() async throws {
			let provider: S3CloudProvider = provider
			let localURL = try makeLocalFile()
			let canceller = TaskCanceller<CloudItemMetadata>()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.txt"),
				URLProtocolMock.handler(onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(statusCode: 503),
				S3CloudProviderTests.listing(of: "file.txt", keys: ["file.txt"])
			]

			let uploadTask = canceller.start {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.txt"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			}
			let metadata = try await cancellingValue(of: uploadTask)

			#expect(CloudPath("/file.txt") == metadata.cloudPath)
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Multipart Uploads

		@Test
		func uploadFileOverThresholdUploadsPartsInOrder() async throws {
			let progress = Progress(totalUnitCount: 1)
			let fractions = OSAllocatedUnfairLock(initialState: [Double]())
			let provider = try makeMultipartProvider(hooks: SplitURLSession.Hooks.recordingTransferProgress(of: progress, into: fractions))
			let localURL = try makeLocalFile(content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let requests = RequestRecorder()
			let onTaskCreationCalled = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin", onRequest: requests.record),
				S3CloudProviderTests.initiateMultipartUpload(requests),
				S3CloudProviderTests.part(1, requests),
				S3CloudProviderTests.part(2, requests),
				S3CloudProviderTests.part(3, requests),
				S3CloudProviderTests.completeMultipartUpload(requests),
				S3CloudProviderTests.listing(of: "file.bin", body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10), onRequest: requests.record)
			]

			let metadata = try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: progress, onTaskCreation: { _ in
				onTaskCreationCalled.withLock { $0 = true }
			})

			#expect(metadata.size == 10)
			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "POST", "PUT", "PUT", "PUT", "POST", "GET"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[1]) == ["uploads": ""])
			#expect(sent[1].value(forHTTPHeaderField: "Content-Type") == "application/octet-stream")
			for (index, request) in sent[2 ... 4].enumerated() {
				let query = S3CloudProviderTests.queryParameters(of: request)
				#expect(String(index + 1) == query["partNumber"])
				#expect(query["uploadId"] == "upload-id")
			}
			#expect(sent[2 ... 4].map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) } == ["0123", "4567", "89"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[5]) == ["uploadId": "upload-id"])
			let completionBody = String(bytes: sent[5].httpBody ?? Data(), encoding: .utf8) ?? ""
			#expect(completionBody.contains("<Part><PartNumber>1</PartNumber><ETag>&quot;etag-1&quot;</ETag></Part><Part><PartNumber>2</PartNumber><ETag>&quot;etag-2&quot;</ETag></Part><Part><PartNumber>3</PartNumber><ETag>&quot;etag-3&quot;</ETag></Part></CompleteMultipartUpload>"), "\(completionBody)")
			#expect(!onTaskCreationCalled.withLock { $0 }, "A task that uploads only a part was passed to onTaskCreation")
			let recordedFractions = fractions.withLock { $0 }
			#expect(recordedFractions.count == 3)
			for (index, (fraction, (bytesBefore, partLength))) in zip(recordedFractions, [(0.0, 4.0), (4.0, 4.0), (8.0, 2.0)]).enumerated() {
				#expect(fraction > (bytesBefore + partLength / 2) / 10, "part \(index)")
				#expect(fraction < 1, "part \(index)")
			}
			#expect(progress.fractionCompleted == 1)
			#expect(try temporaryFiles == uuidNamedTemporaryFiles())
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileAtThresholdUsesSinglePut() async throws {
			let provider = try makeMultipartProvider(multipartUploadThreshold: 10)
			let requests = RequestRecorder()
			let onTaskCreationCalled = OSAllocatedUnfairLock(initialState: false)
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin", onRequest: requests.record),
				URLProtocolMock.handler(onRequest: requests.record),
				S3CloudProviderTests.listing(of: "file.bin", body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10), onRequest: requests.record)
			]

			_ = try await provider.uploadFile(from: makeLocalFile(content: "0123456789"), to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: { _ in
				onTaskCreationCalled.withLock { $0 = true }
			})

			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "PUT", "GET"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[1])["uploadId"] == nil)
			#expect(Data("0123456789".utf8) == sent[1].httpBody)
			#expect(onTaskCreationCalled.withLock { $0 })
		}

		/// The size of a symbolic link's target counts, not the link's own.
		@Test
		func uploadFileThroughSymbolicLinkUsesSizeOfTarget() async throws {
			let provider = try makeMultipartProvider()
			let linkURL = tmpDirURL.appendingPathComponent("link.bin")
			try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: makeLocalFile(content: "0123456789"))
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				S3CloudProviderTests.initiateMultipartUpload(),
				S3CloudProviderTests.part(1, requests),
				S3CloudProviderTests.part(2, requests),
				S3CloudProviderTests.part(3, requests),
				S3CloudProviderTests.completeMultipartUpload(),
				S3CloudProviderTests.listing(of: "file.bin", body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10))
			]

			_ = try await provider.uploadFile(from: linkURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)

			#expect(requests.requests.map { String(bytes: $0.httpBody ?? Data(), encoding: .utf8) } == ["0123", "4567", "89"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func failedPartAbortsMultipartUpload() async throws {
			let provider = try makeMultipartProvider()
			let localURL = try makeLocalFile(content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				S3CloudProviderTests.initiateMultipartUpload(),
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>"),
				S3CloudProviderTests.abortMultipartUpload(requests)
			]

			await #expect(throws: CloudProviderError.unauthorized) { try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
			try assertAborted(requests, temporaryFiles: temporaryFiles)
		}

		/// S3 refuses a completion whose parts don't match the uploaded ones, after which the multipart upload would stay pending.
		@Test
		func failedCompletionAbortsMultipartUpload() async throws {
			let provider = try makeMultipartProvider()
			let localURL = try makeLocalFile(content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				S3CloudProviderTests.initiateMultipartUpload(),
				S3CloudProviderTests.part(1),
				S3CloudProviderTests.part(2),
				S3CloudProviderTests.part(3),
				URLProtocolMock.handler(statusCode: 400, body: "<Error><Code>InvalidPart</Code></Error>"),
				S3CloudProviderTests.abortMultipartUpload(requests)
			]

			let error = try await #require(throws: (any Error).self) { try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
			#expect((error as? S3Error)?.code == "InvalidPart")
			try assertAborted(requests, temporaryFiles: temporaryFiles)
		}

		/// A file that got shorter during the upload must not complete as a shorter object, also when only its last part is short. A failed abort doesn't replace that error.
		@Test
		func fileThatGetsShorterDuringMultipartUploadAborts() async throws {
			let provider = try makeMultipartProvider()
			let localURL = try makeLocalFile(content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				S3CloudProviderTests.initiateMultipartUpload(),
				S3CloudProviderTests.part(1),
				URLProtocolMock.handler(headerFields: ["ETag": "\"etag-2\""], onRequest: { _ in
					try? FileHandle(forWritingTo: localURL).truncate(atOffset: 9)
				}),
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>", onRequest: requests.record)
			]

			let error = try await #require(throws: (any Error).self) { try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
			#expect((error as? CocoaError)?.code == .fileReadCorruptFile)
			try assertAborted(requests, temporaryFiles: temporaryFiles)
		}

		@Test
		func unreadableFileAbortsMultipartUpload() async throws {
			let provider = try makeMultipartProvider()
			let localURL = try makeLocalFile(content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				URLProtocolMock.handler(body: S3MockResponse.initiateMultipartUploadResult(), onRequest: { _ in
					try? FileManager.default.removeItem(at: localURL)
				}),
				S3CloudProviderTests.abortMultipartUpload(requests)
			]

			let error = try await #require(throws: (any Error).self) { try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
			#expect((error as? CocoaError)?.code == .fileNoSuchFile)
			try assertAborted(requests, temporaryFiles: temporaryFiles)
		}

		/// The abort of a cancelled upload is retried after a transient failure, so that no multipart upload is left behind.
		@Test
		func cancellationDuringPartAbortsMultipartUpload() async throws {
			let provider = try makeMultipartProvider()
			let localURL = try makeLocalFile(content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let canceller = TaskCanceller<CloudItemMetadata>()
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				S3CloudProviderTests.initiateMultipartUpload(),
				URLProtocolMock.handler(headerFields: ["ETag": "\"etag-1\""], onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(statusCode: 503, onRequest: requests.record),
				S3CloudProviderTests.abortMultipartUpload(requests)
			]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: canceller.start {
					try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)
				})
			}
			try assertAborted(requests, attempts: 2, temporaryFiles: temporaryFiles)
		}

		/// The last part leaves no cancellation check in the loop, so the one before the completion stops the upload.
		@Test
		func cancellationDuringLastPartAbortsMultipartUpload() async throws {
			let provider = try makeMultipartProvider()
			let localURL = try makeLocalFile(content: "0123456789")
			let temporaryFiles = try uuidNamedTemporaryFiles()
			let canceller = TaskCanceller<CloudItemMetadata>()
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				S3CloudProviderTests.initiateMultipartUpload(),
				S3CloudProviderTests.part(1),
				S3CloudProviderTests.part(2),
				URLProtocolMock.handler(headerFields: ["ETag": "\"etag-3\""], onRequest: { _ in
					canceller.cancel()
				}),
				S3CloudProviderTests.abortMultipartUpload(requests)
			]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: canceller.start {
					try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)
				})
			}
			try assertAborted(requests, temporaryFiles: temporaryFiles)
		}

		/// The completion commits the upload, so a cancellation during it must not cut short its retries or abort the upload.
		@Test
		func cancellationDuringCompletionCompletesUpload() async throws {
			let provider = try makeMultipartProvider()
			let localURL = try makeLocalFile(content: "0123456789")
			let canceller = TaskCanceller<CloudItemMetadata>()
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "file.bin"),
				S3CloudProviderTests.initiateMultipartUpload(),
				S3CloudProviderTests.part(1),
				S3CloudProviderTests.part(2),
				S3CloudProviderTests.part(3),
				URLProtocolMock.handler(statusCode: 503, onRequest: { request in
					requests.record(request)
					canceller.cancel()
				}),
				S3CloudProviderTests.completeMultipartUpload(requests),
				S3CloudProviderTests.listing(of: "file.bin", body: S3MockResponse.listBucketResult(keys: ["file.bin"], size: 10), onRequest: requests.record)
			]

			let metadata = try await cancellingValue(of: canceller.start {
				try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil)
			})

			#expect(CloudPath("/file.bin") == metadata.cloudPath)
			#expect(requests.requests.map(\.httpMethod) == ["POST", "POST", "GET"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func uploadFileOverMaximumSizeThrowsBeforeAnyRequest() async throws {
			let provider = try makeMultipartProvider(maxPartCount: 1)
			let localURL = try makeFileOverMaximumSize()
			URLProtocolMock.requestHandler = [URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: []))]

			let error = try await #require(throws: (any Error).self) { try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil) }
			#expect((error as? URLError)?.code == .dataLengthExceedsMaximum)
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		/// The local file's checks run inside the upload's logged span, so each failure is logged once.
		@Test
		func uploadFileLogsFailedLocalChecksOnce() async throws {
			let provider = try makeMultipartProvider(maxPartCount: 1)
			let oversizedURL = try makeFileOverMaximumSize()
			let cases: [(localURL: URL, isExpected: (Error) -> Bool)] = [
				(tmpDirURL.appendingPathComponent("missing.bin"), { ($0 as? CloudProviderError) == .itemNotFound }),
				(oversizedURL, { ($0 as? URLError)?.code == .dataLengthExceedsMaximum })
			]
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}

			for (localURL, isExpected) in cases {
				let error = try await #require(throws: (any Error).self) { try await provider.uploadFile(from: localURL, to: CloudPath("/file.bin"), replaceExisting: false, progress: nil, onTaskCreation: nil) }

				#expect(isExpected(error), "\(error)")
				let operation = "S3CloudProvider: uploadFile(from: \(localURL), to: /file.bin, replaceExisting: false)"
				let messages = logCapture.messages
				#expect(messages.filter { $0 == "\(operation) called" }.count == 1, "\(localURL)")
				#expect(messages.filter { $0.hasPrefix("\(operation) failed with error:") }.count == 1, "\(localURL)")
			}
		}

		@Test
		func testPartSize() {
			let mebibyte = 1024 * 1024
			#expect(32 * mebibyte == S3CloudProvider.partSize(forFileSize: 4768 * mebibyte + 1, minPartSize: 32 * mebibyte, maxPartCount: 1000))
			#expect(41 * mebibyte == S3CloudProvider.partSize(forFileSize: 1000 * 40 * mebibyte + 1, minPartSize: 32 * mebibyte, maxPartCount: 1000))
			#expect(S3Client.maxPartSize == S3CloudProvider.partSize(forFileSize: 1000 * S3Client.maxPartSize, minPartSize: 32 * mebibyte, maxPartCount: 1000))
			#expect(S3Client.maxPartSize + mebibyte == S3CloudProvider.partSize(forFileSize: 1000 * S3Client.maxPartSize + 1, minPartSize: 32 * mebibyte, maxPartCount: 1000))
		}

		// MARK: - Requests

		@Test
		func fetchItemListRequestsOnePageOfFolder() async throws {
			let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], commonPrefixes: ["folder/sub/"], nextContinuationToken: "next"), onRequest: { request in
					requests.withLock { $0.append(request) }
				})
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: "token")

			let request = try #require(requests.withLock { $0 }.first)
			#expect(request.httpMethod == "GET")
			#expect(request.url?.path == "/exampleBucket")
			#expect(S3CloudProviderTests.queryParameters(of: request) == ["list-type": "2", "prefix": "folder/", "max-keys": "1000", "delimiter": "/", "continuation-token": "token"])
			#expect([CloudPath("/folder/a.txt"), CloudPath("/folder/sub")] == itemList.items.map(\.cloudPath))
			#expect(itemList.items.map(\.itemType) == [.file, .folder])
			#expect(itemList.nextPageToken == "next")
		}

		@Test
		func fetchItemListParsesLastModified() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", body: S3MockResponse.listBucketResult(keys: ["folder/", "folder/a.txt"], lastModified: "2026-10-18T12:34:56.500Z"))
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/folder"), withPageToken: nil)

			#expect([Date(timeIntervalSince1970: 1_792_326_896.5)] == itemList.items.map(\.lastModifiedDate))
		}

		@Test
		func listingSkipsKeysWithSegmentsThatAreNoSinglePathComponent() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "f/", keys: ["f/ok.txt", "f/.."], commonPrefixes: ["f/../", "f//", "f/./", "f/sub/"]),
				S3CloudProviderTests.listing(of: "", keys: ["ok.txt", ""], commonPrefixes: ["/"])
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/f"), withPageToken: nil)
			let rootItemList = try await provider.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)

			#expect([CloudPath("/f/ok.txt"), CloudPath("/f/sub")] == itemList.items.map(\.cloudPath))
			#expect([CloudPath("/ok.txt")] == rootItemList.items.map(\.cloudPath))
			let skippedKeys = logCapture.messages.filter { $0.hasSuffix("because one of its segments is no single path component") }
			#expect(["f/..", "f/../", "f//", "f/./", "/", ""].map { "S3CloudProvider: skipping key \($0), because one of its segments is no single path component" }.sorted() == skippedKeys.sorted())
		}

		/// The folder's marker and the left-out keys prove that the folder exists, so the listing skips the existence check. That check would fail if an object `f` exists beside them.
		@Test
		func listingReturnsEmptyPageWithTokenIfPageHoldsOnlyMarkerOrSkippedKeys() async throws {
			for keys in [["f/"], ["f/.", "f/.."]] {
				URLProtocolMock.requestHandler = [
					S3CloudProviderTests.listing(of: "f/", keys: keys, nextContinuationToken: "next"),
					S3CloudProviderTests.listing(of: "f/", keys: ["f/ok.txt"])
				]

				let firstPage = try await provider.fetchItemList(forFolderAt: CloudPath("/f"), withPageToken: nil)
				#expect(URLProtocolMock.requestHandler.count == 1, "\(keys)")
				let secondPage = try await provider.fetchItemList(forFolderAt: CloudPath("/f"), withPageToken: firstPage.nextPageToken)

				#expect(firstPage.items.isEmpty, "\(keys)")
				#expect(firstPage.nextPageToken == "next", "\(keys)")
				#expect([CloudPath("/f/ok.txt")] == secondPage.items.map(\.cloudPath), "\(keys)")
			}
		}

		/// A server that ignores the delimiter or the prefix must not get items listed that aren't directly in the folder, where the vault layer would trap on a path that is too deep.
		@Test
		func listingSkipsKeysThatAreNotDirectlyBelowFolder() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "f/", keys: ["f/", "f/ok.txt", "f/sub/deep.txt", "g/other.txt", "f"], commonPrefixes: ["f/sub/deeper/", "f/a/\u{301}b/"])
			]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/f"), withPageToken: nil)

			#expect([CloudPath("/f/ok.txt")] == itemList.items.map(\.cloudPath))
		}

		@Test
		func listingKeepsNameStartingWithCombiningMark() async throws {
			URLProtocolMock.requestHandler = [S3CloudProviderTests.listing(of: "f/", keys: ["f/\u{301}report.txt"])]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/f"), withPageToken: nil)

			#expect(itemList.items.map(\.name) == ["\u{301}report.txt"])
			#expect([CloudPath("/f")] == itemList.items.map { $0.cloudPath.deletingLastPathComponent() })
		}

		/// A page without keys below the prefix may be the listing of a missing folder, so the listing checks the folder even if it left out keys outside the prefix.
		@Test
		func listingOfMissingFolderThrowsItemNotFound() async throws {
			for keys in [[], ["g/other.txt"]] {
				URLProtocolMock.requestHandler = [
					S3CloudProviderTests.listing(of: "f/", keys: keys),
					S3CloudProviderTests.listing(of: "f")
				]

				await #expect(throws: CloudProviderError.itemNotFound, "\(keys)") { try await provider.fetchItemList(forFolderAt: CloudPath("/f"), withPageToken: nil) }
				#expect(URLProtocolMock.requestHandler.isEmpty, "\(keys)")
			}
		}

		@Test
		func listingOfFileThrowsItemTypeMismatch() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "f/"),
				S3CloudProviderTests.listing(of: "f", keys: ["f"])
			]

			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await provider.fetchItemList(forFolderAt: CloudPath("/f"), withPageToken: nil) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A prepended mark such as U+0600 forms one `Character` with the slash that follows it, so the key's segments and the marker's trailing slash are found by scalar.
		@Test
		func listingOfFolderWhoseNameEndsWithPrependedMark() async throws {
			URLProtocolMock.requestHandler = [S3CloudProviderTests.listing(of: "f\u{600}/", keys: ["f\u{600}/", "f\u{600}/x.txt"])]

			let itemList = try await provider.fetchItemList(forFolderAt: CloudPath("/f\u{600}"), withPageToken: nil)

			#expect(itemList.items.map(\.cloudPath.path) == ["/f\u{600}/x.txt"])
		}

		@Test
		func fetchItemMetadataOfNestedFileAndFolder() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "a/b.txt", keys: ["a/b.txt"]),
				S3CloudProviderTests.listing(of: "a/c", commonPrefixes: ["a/c/"])
			]

			let file = try await provider.fetchItemMetadata(at: CloudPath("/a/b.txt"))
			let folder = try await provider.fetchItemMetadata(at: CloudPath("/a/c"))

			#expect([CloudPath("/a/b.txt"), CloudPath("/a/c")] == [file.cloudPath, folder.cloudPath])
			#expect([file.itemType, folder.itemType] == [.file, .folder])
		}

		@Test
		func fetchItemMetadataOfRootIgnoresKeyThatStandardizesToRoot() async throws {
			URLProtocolMock.requestHandler = [S3CloudProviderTests.listing(of: "", keys: [".", ""])]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/")) }
		}

		@Test
		func fetchItemMetadataOfFolderListedAfterSibling() async throws {
			let requests = OSAllocatedUnfairLock(initialState: [URLRequest]())
			let recordRequest: @Sendable (URLRequest) -> Void = { request in
				requests.withLock { $0.append(request) }
			}
			URLProtocolMock.requestHandler = [
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: [], commonPrefixes: ["folder 2/"], nextContinuationToken: "next"), onRequest: recordRequest),
				URLProtocolMock.handler(body: S3MockResponse.listBucketResult(keys: ["folder/"]), onRequest: recordRequest)
			]

			let metadata = try await provider.fetchItemMetadata(at: CloudPath("/folder"))

			#expect(CloudPath("/folder") == metadata.cloudPath)
			#expect(metadata.itemType == .folder)
			#expect(requests.withLock { $0 }.map(S3CloudProviderTests.queryParameters(of:)) == [
				["list-type": "2", "prefix": "folder", "max-keys": "1", "delimiter": "/"],
				["list-type": "2", "prefix": "folder/", "max-keys": "1", "delimiter": "/"]
			])
		}

		@Test
		func fetchItemMetadataDoesNotListFolderAfterSiblingInCancelledTask() async throws {
			let provider: S3CloudProvider = provider
			let canceller = TaskCanceller<CloudItemMetadata>()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder", commonPrefixes: ["folder 2/"], nextContinuationToken: "next", onRequest: { _ in
					canceller.cancel()
				}),
				S3CloudProviderTests.listing(of: "folder/", keys: ["folder/"])
			]

			let fetchTask = canceller.start {
				try await provider.fetchItemMetadata(at: CloudPath("/folder"))
			}

			await #expect(throws: CancellationError.self) { try await cancellingValue(of: fetchTask) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func fetchItemMetadataThrowsItemNotFoundIfOnlySiblingExists() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder", keys: ["folder.txt"], nextContinuationToken: "next"),
				S3CloudProviderTests.listing(of: "folder/")
			]

			await #expect(throws: CloudProviderError.itemNotFound) { try await provider.fetchItemMetadata(at: CloudPath("/folder")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func createFolderPutsFolderMarker() async throws {
			let markerRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder"),
				URLProtocolMock.handler(onRequest: { request in
					markerRequest.withLock { $0 = request }
				})
			]

			try await provider.createFolder(at: CloudPath("/folder"))

			let request = try #require(markerRequest.withLock { $0 })
			#expect(request.httpMethod == "PUT")
			#expect(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } == "/exampleBucket/folder/")
			#expect(request.value(forHTTPHeaderField: "Content-Type") == "application/x-directory")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteFolderDeletesEveryPage() async throws {
			let requests = OSAllocatedUnfairLock(initialState: [(request: URLRequest, body: String)]())
			let recordRequest: @Sendable (URLRequest) -> Void = { request in
				let body = String(bytes: URLProtocolMock.body(of: request), encoding: .utf8) ?? ""
				requests.withLock { $0.append((request, body)) }
			}
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/", "folder/a.txt"], nextContinuationToken: "next", onRequest: recordRequest),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: recordRequest),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"], onRequest: recordRequest),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: recordRequest)
			]

			try await provider.deleteFolder(at: CloudPath("/folder"))

			let sent = requests.withLock { $0 }
			#expect(sent.map(\.request.httpMethod) == ["GET", "POST", "GET", "POST"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[0].request) == ["list-type": "2", "prefix": "folder/", "max-keys": "1000"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[2].request) == ["list-type": "2", "prefix": "folder/", "max-keys": "1000", "continuation-token": "next"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[1].request) == ["delete": ""])
			#expect(sent[1].body.contains("<Object><Key>folder/</Key></Object><Object><Key>folder/a.txt</Key></Object>"), "\(sent[1].body)")
			#expect(sent[3].body.contains("<Object><Key>folder/b.txt</Key></Object>"), "\(sent[3].body)")
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteFolderLeavesKeysOutsideFolder() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt", "folder2/b.txt"]),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.deleteFolder(at: CloudPath("/folder"))

			#expect(requests.requests.map(S3CloudProviderTests.deletedKeys(of:)) == [["folder/a.txt"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFolderCopiesAndDeletesEveryPage() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(keys: ["folder/", "folder/a.txt"], nextContinuationToken: "next", onRequest: requests.record) + [
				S3CloudProviderTests.copyObject(requests),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/sub/b.txt"], onRequest: requests.record),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target"))

			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "PUT", "PUT", "POST", "GET", "PUT", "POST"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[0]) == ["list-type": "2", "prefix": "folder/", "max-keys": "1000"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[4]) == ["list-type": "2", "prefix": "folder/", "max-keys": "1000", "continuation-token": "next"])
			#expect(S3CloudProviderTests.copySources(of: sent[1 ... 2]) == ["/exampleBucket/target/": "exampleBucket/folder/", "/exampleBucket/target/a.txt": "exampleBucket/folder/a.txt"])
			#expect(S3CloudProviderTests.copySources(of: sent[5 ... 5]) == ["/exampleBucket/target/sub/b.txt": "exampleBucket/folder/sub/b.txt"])
			#expect(S3CloudProviderTests.deletedKeys(of: sent[3]) == ["folder/", "folder/a.txt"])
			#expect(S3CloudProviderTests.deletedKeys(of: sent[6]) == ["folder/sub/b.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFolderLeavesKeysOutsideFolderAndCopiesKeyWithoutSize() async throws {
			let requests = RequestRecorder()
			let contents = "<Contents><Key>folder/a.txt</Key><Size>7</Size></Contents><Contents><Key>folder2/b.txt</Key><Size>7</Size></Contents><Contents><Key>folder/c.txt</Key></Contents>"
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(firstPageBody: "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><IsTruncated>false</IsTruncated>\(contents)</ListBucketResult>", onRequest: requests.record) + [
				S3CloudProviderTests.copyObject(requests),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target"))

			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "PUT", "PUT", "POST"])
			#expect(S3CloudProviderTests.copySources(of: sent[1 ... 2]) == ["/exampleBucket/target/a.txt": "exampleBucket/folder/a.txt", "/exampleBucket/target/c.txt": "exampleBucket/folder/c.txt"])
			#expect(S3CloudProviderTests.deletedKeys(of: sent[3]) == ["folder/a.txt", "folder/c.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFolderWithFailedCopyDeletesNothing() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(keys: ["folder/a.txt"], onRequest: requests.record) + [
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>", onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.unauthorized) { try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }

			#expect(requests.requests.map(\.httpMethod) == ["GET", "PUT"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Mutation Checks

		/// A folder is judged by a listing of its prefix, and a file by a listing of its key. A source folder whose prefix holds nothing is then looked up by its key.
		@Test
		func mutationChecksFollowTheSharedContract() async throws {
			let cases = try MutationGuardCases.make(localURL: makeLocalFile()) { kind in
				switch kind {
				case .deleteFileOfFolder, .moveFileOfFolder:
					return [S3CloudProviderTests.listing(of: "folder", commonPrefixes: ["folder/"])]
				case .deleteFolderOfFile, .moveFolderOfFile:
					return [S3CloudProviderTests.listing(of: "file.txt/", recursive: true), S3CloudProviderTests.listing(of: "file.txt", keys: ["file.txt"])]
				case .createFolderInFile, .uploadFileIntoFile:
					return [S3CloudProviderTests.listing(of: "file.txt/sub"), S3CloudProviderTests.listing(of: "file.txt/")]
				case .moveFileIntoFile, .moveFolderIntoFile:
					return [S3CloudProviderTests.listing(of: "file.txt/")]
				case .createFolderBelowFileMidPath:
					return [S3CloudProviderTests.listing(of: "file.txt/x/new"), S3CloudProviderTests.listing(of: "file.txt/x/")]
				case .missingSourceOntoExistingTarget:
					return [S3CloudProviderTests.listing(of: "missing.txt")]
				case .missingSourceIntoMissingParent:
					return [S3CloudProviderTests.listing(of: "missing/")]
				case .createFolderAtRoot, .uploadFileToRoot, .moveFileToRoot, .moveFolderToRoot, .deleteFileOfRoot, .deleteFolderOfRoot, .moveFileOfRoot, .moveFolderOfRoot:
					return []
				}
			}
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try S3CloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		/// No mutation takes the root as its source, because a folder operation would act on the whole bucket. Neither sends a request.
		@Test
		func rootSourceThrowsWithoutRequest() async throws {
			let cases = [
				MutationGuardCase(name: "moveFolder of the root into a folder", responses: [], expected: .itemTypeMismatch) { try await $0.moveFolder(from: .root, to: CloudPath("/folder/x")) },
				MutationGuardCase(name: "moveFolder of the root to the root", responses: [], expected: .itemTypeMismatch) { try await $0.moveFolder(from: .root, to: .root) }
			]
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try S3CloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		/// Each path maps to a key: one that no listing shows (`..`, `a/../b`) or, for a relative path, the key of its absolute spelling.
		@Test
		func unresolvablePathsThrowWithoutRequest() async throws {
			let cases = try MutationGuardCases.makeInvalidPathCases(localURL: makeLocalFile(), downloadURL: tmpDirURL.appendingPathComponent("download.txt"), paths: MutationGuardCases.unresolvablePaths())
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try S3CloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		/// The first page of the folder's recursive listing proves that it is a folder and is deleted without listing it again.
		@Test
		func deleteFolderOfKeyThatIsAlsoPrefixDeletesOnlyPrefix() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "a/", recursive: true, keys: ["a/x"]),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.deleteFolder(at: CloudPath("/a"))

			#expect(requests.requests.map(S3CloudProviderTests.deletedKeys(of:)) == [["a/x"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A vault folder delete takes `itemNotFound` for a folder that is gone, so a folder that appears after its empty listing is deleted, not reported as missing.
		@Test
		func deleteFolderOfFolderAppearingAfterItsListingDeletesIt() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "x/", recursive: true),
				S3CloudProviderTests.listing(of: "x", commonPrefixes: ["x/"]),
				S3CloudProviderTests.listing(of: "x/", recursive: true, keys: ["x/"]),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.deleteFolder(at: CloudPath("/x"))

			#expect(requests.requests.map(S3CloudProviderTests.deletedKeys(of:)) == [["x/"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Nothing at the path, also once a folder that appeared after the first listing is gone again, must not count as a deleted or moved folder.
		@Test
		func missingFolderThrowsItemNotFoundWithoutWriting() async throws {
			let missing = [S3CloudProviderTests.listing(of: "x/", recursive: true), S3CloudProviderTests.listing(of: "x")]
			let goneAgain = [S3CloudProviderTests.listing(of: "x/", recursive: true), S3CloudProviderTests.listing(of: "x", commonPrefixes: ["x/"]), S3CloudProviderTests.listing(of: "x/", recursive: true)]
			let cases = [
				MutationGuardCase(name: "deleteFolder of a missing folder", responses: missing, expected: .itemNotFound) { try await $0.deleteFolder(at: CloudPath("/x")) },
				MutationGuardCase(name: "moveFolder of a missing folder", responses: missing, expected: .itemNotFound) { try await $0.moveFolder(from: CloudPath("/x"), to: CloudPath("/y")) },
				MutationGuardCase(name: "deleteFolder of a folder gone again", responses: goneAgain, expected: .itemNotFound) { try await $0.deleteFolder(at: CloudPath("/x")) },
				MutationGuardCase(name: "moveFolder of a folder gone again", responses: goneAgain, expected: .itemNotFound) { try await $0.moveFolder(from: CloudPath("/x"), to: CloudPath("/y")) }
			]
			try await MutationGuardCases.expectErrorsConsumingAllResponses(cases) { try S3CloudProvider(client: .mocked(), maxPageSize: .max) }
		}

		@Test
		func deleteFileOfKeyThatIsAlsoPrefixDeletesOnlyObject() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "a", keys: ["a"]),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			try await provider.deleteFile(at: CloudPath("/a"))

			#expect(requests.requests.map(\.httpMethod) == ["DELETE"])
			#expect(requests.requests.map { $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } } == ["/exampleBucket/a"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A parent is proven by an object below it, its marker, or a common prefix of a folder without a marker.
		@Test(arguments: [(keys: ["a/x"], commonPrefixes: [String]()), (keys: [], commonPrefixes: ["a/sub/"])])
		func keyThatIsAlsoPrefixIsParentFolder(keys: [String], commonPrefixes: [String]) async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "a/new"),
				S3CloudProviderTests.listing(of: "a/", keys: keys, commonPrefixes: commonPrefixes),
				URLProtocolMock.handler(onRequest: requests.record)
			]

			try await provider.createFolder(at: CloudPath("/a/new"))

			#expect(requests.requests.map { $0.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } } == ["/exampleBucket/a/new/"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFolderOfKeyThatIsAlsoPrefixMovesOnlyPrefix() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "a/", recursive: true, keys: ["a/x"]),
				S3CloudProviderTests.listing(of: "b"),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.moveFolder(from: CloudPath("/a"), to: CloudPath("/b"))

			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["PUT", "POST"])
			#expect(S3CloudProviderTests.copySources(of: sent[0 ... 0]) == ["/exampleBucket/b/x": "exampleBucket/a/x"])
			#expect(S3CloudProviderTests.deletedKeys(of: sent[1]) == ["a/x"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFileIntoFolderChecksTargetParentFirst() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", keys: ["folder/"], onRequest: requests.record),
				S3CloudProviderTests.listing(of: "a.txt", keys: ["a.txt"], onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/b.txt", onRequest: requests.record),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(statusCode: 204, onRequest: requests.record)
			]

			try await provider.moveFile(from: CloudPath("/a.txt"), to: CloudPath("/folder/b.txt"))

			#expect(requests.requests.map(\.httpMethod) == ["GET", "GET", "GET", "PUT", "DELETE"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The first page of the source's recursive listing proves that it is a folder and is copied without listing it again.
		@Test
		func moveFolderIntoFolderListsSourceOnce() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", keys: ["folder/"], onRequest: requests.record),
				S3CloudProviderTests.listing(of: "src/", recursive: true, keys: ["src/a.txt"], onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/dst", onRequest: requests.record),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.moveFolder(from: CloudPath("/src"), to: CloudPath("/folder/dst"))

			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "GET", "GET", "PUT", "POST"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[1]) == ["list-type": "2", "prefix": "src/", "max-keys": "1000"])
			#expect(S3CloudProviderTests.copySources(of: sent[3 ... 3]) == ["/exampleBucket/folder/dst/a.txt": "exampleBucket/src/a.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Only a server that ignores the prefix returns a page whose keys all lie outside it.
		@Test
		func moveFolderListsPastPagesWithoutObjectsBeforeCopying() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["other/x"], nextContinuationToken: "next", onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"], onRequest: requests.record),
				S3CloudProviderTests.listing(of: "target"),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target"))

			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "GET", "PUT", "POST"])
			#expect(S3CloudProviderTests.queryParameters(of: sent[1])["continuation-token"] == "next")
			#expect(S3CloudProviderTests.copySources(of: sent[2 ... 2]) == ["/exampleBucket/target/a.txt": "exampleBucket/folder/a.txt"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A request that a mutation sends before its commit point is followed by a cancellation check, including the last one before the write.
		@Test
		func cancellationDuringChecksSendsNoFurtherRequest() async throws {
			let cases = [
				CancelledMutationCase(name: "createFolder after the parent", responses: { canceller in
					[S3CloudProviderTests.listing(of: "folder/new"), S3CloudProviderTests.listing(of: "folder/", keys: ["folder/"], onRequest: { _ in canceller.cancel() }), URLProtocolMock.handler()]
				}, operation: { try await $0.createFolder(at: CloudPath("/folder/new")) }, remainingResponses: 1),
				CancelledMutationCase(name: "deleteFile after the file", responses: { canceller in
					[S3CloudProviderTests.listing(of: "a.txt", keys: ["a.txt"], onRequest: { _ in canceller.cancel() }), URLProtocolMock.handler(statusCode: 204)]
				}, operation: { try await $0.deleteFile(at: CloudPath("/a.txt")) }, remainingResponses: 1),
				CancelledMutationCase(name: "deleteFolder after the empty prefix", responses: { canceller in
					[S3CloudProviderTests.listing(of: "x/", recursive: true, onRequest: { _ in canceller.cancel() }), S3CloudProviderTests.listing(of: "x", commonPrefixes: ["x/"])]
				}, operation: { try await $0.deleteFolder(at: CloudPath("/x")) }, remainingResponses: 1),
				CancelledMutationCase(name: "deleteFolder after the key lookup that follows the empty prefix", responses: { canceller in
					[S3CloudProviderTests.listing(of: "x/", recursive: true), S3CloudProviderTests.listing(of: "x", commonPrefixes: ["x/"], onRequest: { _ in canceller.cancel() }), S3CloudProviderTests.listing(of: "x/", recursive: true, keys: ["x/a.txt"])]
				}, operation: { try await $0.deleteFolder(at: CloudPath("/x")) }, remainingResponses: 1),
				CancelledMutationCase(name: "moveFile after the target's parent", responses: { canceller in
					[S3CloudProviderTests.listing(of: "folder/", keys: ["folder/"], onRequest: { _ in canceller.cancel() }), S3CloudProviderTests.listing(of: "a.txt", keys: ["a.txt"])]
				}, operation: { try await $0.moveFile(from: CloudPath("/a.txt"), to: CloudPath("/folder/b.txt")) }, remainingResponses: 1),
				CancelledMutationCase(name: "moveFile after the target", responses: { canceller in
					[S3CloudProviderTests.listing(of: "a.txt", keys: ["a.txt"]), S3CloudProviderTests.listing(of: "b.txt", onRequest: { _ in canceller.cancel() }), URLProtocolMock.handler(body: S3MockResponse.copyObjectResult)]
				}, operation: { try await $0.moveFile(from: CloudPath("/a.txt"), to: CloudPath("/b.txt")) }, remainingResponses: 1),
				CancelledMutationCase(name: "moveFolder after the target", responses: { canceller in
					[S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"]), S3CloudProviderTests.listing(of: "target", onRequest: { _ in canceller.cancel() }), URLProtocolMock.handler(body: S3MockResponse.copyObjectResult)]
				}, operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }, remainingResponses: 1),
				CancelledMutationCase(name: "moveFolder after a recursive page without objects", responses: { canceller in
					[
						S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["other/x"], nextContinuationToken: "next", onRequest: { _ in canceller.cancel() }),
						S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"]),
						S3CloudProviderTests.listing(of: "target"),
						URLProtocolMock.handler(body: S3MockResponse.copyObjectResult)
					]
				}, operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }, remainingResponses: 3),
				CancelledMutationCase(name: "moveFolder after the page with objects that follows a page without", responses: { canceller in
					[
						S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["other/x"], nextContinuationToken: "next"),
						S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"], onRequest: { _ in canceller.cancel() }),
						S3CloudProviderTests.listing(of: "target"),
						URLProtocolMock.handler(body: S3MockResponse.copyObjectResult)
					]
				}, operation: { try await $0.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }, remainingResponses: 2)
			]
			try await expectOutcomes(of: cases)
		}

		/// The PUT of a folder marker and the DELETE of a file are their operations' commit points. Their retries therefore run even if the task is cancelled during the first attempt, and the call returns the write's own result.
		@Test
		func cancelledMutationsStillFinishTheirRequests() async throws {
			let createFolder: @Sendable (S3CloudProvider) async throws -> Void = { try await $0.createFolder(at: CloudPath("/folder")) }
			let deleteFile: @Sendable (S3CloudProvider) async throws -> Void = { try await $0.deleteFile(at: CloudPath("/a.txt")) }
			let missingFolder = S3CloudProviderTests.listing(of: "folder")
			let existingFile = S3CloudProviderTests.listing(of: "a.txt", keys: ["a.txt"])
			let cases = [
				CancelledMutationCase(name: "createFolder", responses: S3CloudProviderTests.cancellingFirstWrite(after: missingFolder, retries: [URLProtocolMock.handler()]), operation: createFolder, remainingResponses: 0, isExpected: { $0 == nil }),
				CancelledMutationCase(name: "createFolder with exhausted retries", responses: S3CloudProviderTests.cancellingFirstWrite(after: missingFolder, retries: Array(repeating: URLProtocolMock.handler(statusCode: 503), count: 3)), operation: createFolder, remainingResponses: 0, isExpected: { ($0 as? S3Error)?.statusCode == 503 }),
				CancelledMutationCase(name: "deleteFile", responses: S3CloudProviderTests.cancellingFirstWrite(after: existingFile, retries: [URLProtocolMock.handler(statusCode: 204)]), operation: deleteFile, remainingResponses: 0, isExpected: { $0 == nil }),
				CancelledMutationCase(name: "refused deleteFile", responses: S3CloudProviderTests.cancellingFirstWrite(after: existingFile, retries: [URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>")]), operation: deleteFile, remainingResponses: 0, isExpected: { ($0 as? CloudProviderError) == .deletionIncomplete })
			]
			try await expectOutcomes(of: cases)
		}

		/// Runs each case in a task that its responses cancel, and expects its outcome and the number of responses that it leaves unconsumed.
		private func expectOutcomes(of cases: [CancelledMutationCase], sourceLocation: SourceLocation = #_sourceLocation) async throws {
			for testCase in cases {
				let provider: S3CloudProvider = provider
				let canceller = TaskCanceller<Void>()
				URLProtocolMock.requestHandler = testCase.responses(canceller)

				let operation = testCase.operation
				let task = canceller.start { try await operation(provider) }
				let error: Error?
				do {
					try await cancellingValue(of: task)
					error = nil
				} catch let thrownError {
					error = thrownError
				}
				#expect(testCase.isExpected(error), "\(testCase.name): \(String(describing: error))", sourceLocation: sourceLocation)
				#expect(URLProtocolMock.requestHandler.count == testCase.remainingResponses, "\(testCase.name)", sourceLocation: sourceLocation)
			}
		}

		// MARK: - Refused Deletions

		@Test
		func deleteFolderWithRefusedKeysDeletesEveryPageAndThrowsDeletionIncomplete() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/", "folder/a.txt"], nextContinuationToken: "next"),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "AccessDenied")]), onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"]),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFolder(at: CloudPath("/folder")) }
			#expect(requests.requests.map(S3CloudProviderTests.deletedKeys(of:)) == [["folder/", "folder/a.txt"], ["folder/b.txt"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A 403 for the whole request is a refusal rather than a sign of wrong credentials, because the listings before it succeeded.
		@Test
		func deleteFolderWithFailedDeleteRequestOnFirstPageDeletesEveryPage() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"], nextContinuationToken: "next"),
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>", onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"]),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFolder(at: CloudPath("/folder")) }
			#expect(requests.requests.map(S3CloudProviderTests.deletedKeys(of:)) == [["folder/a.txt"], ["folder/b.txt"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A later failure must not replace the refusal, because a vault could then skip the error and delete the folder's reference.
		@Test
		func deleteFolderWithRefusalThenListingFailureThrowsDeletionIncomplete() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"], nextContinuationToken: "next"),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "AccessDenied")])),
				URLProtocolMock.handler(statusCode: 400, body: "<Error><Code>InvalidArgument</Code></Error>")
			]

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFolder(at: CloudPath("/folder")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func deleteFolderWithTransportFailureDuringBatchResendThrowsDeletionIncomplete() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"]),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "SlowDown")]))
			] + Array(repeating: S3MockResponse.failure(.networkConnectionLost), count: 3)

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFolder(at: CloudPath("/folder")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// S3 answered, although with a result that can't be read, so the batch counts as refused and the next page is still deleted.
		@Test
		func deleteFolderWithUnreadableDeleteResultOnFirstPageDeletesEveryPage() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"], nextContinuationToken: "next")
			] + Array(repeating: URLProtocolMock.handler(body: S3MockResponse.copyObjectResult), count: 4) + [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"]),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFolder(at: CloudPath("/folder")) }
			#expect(requests.requests.map(S3CloudProviderTests.deletedKeys(of:)) == [["folder/b.txt"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The task is cancelled while page 2 is listed, so the check before its deletion stops the delete.
		@Test
		func deleteFolderCancelledAfterRefusalThrowsCancellationError() async throws {
			let provider: S3CloudProvider = provider
			let canceller = TaskCanceller<Void>()
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/a.txt"], nextContinuationToken: "next"),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "AccessDenied")])),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"], onRequest: { _ in
					canceller.cancel()
				}),
				URLProtocolMock.handler(body: "<DeleteResult/>")
			]

			await #expect(throws: CancellationError.self) {
				try await cancellingValue(of: canceller.start {
					try await provider.deleteFolder(at: CloudPath("/folder"))
				})
			}
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func moveFolderWithRefusedKeysCopiesEveryPageAndThrowsMoveCompleted() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(keys: ["folder/a.txt"], nextContinuationToken: "next", onRequest: requests.record) + [
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "AccessDenied")]), onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"], onRequest: requests.record),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }
			let sent = requests.requests
			#expect(sent.map(\.httpMethod) == ["GET", "PUT", "POST", "GET", "PUT", "POST"])
			#expect(sent.filter { $0.httpMethod == "POST" }.map(S3CloudProviderTests.deletedKeys(of:)) == [["folder/a.txt"], ["folder/b.txt"]])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		@Test
		func moveFolderWithFailedDeleteRequestCopiesEveryPageAndThrowsMoveCompleted() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(keys: ["folder/a.txt"], nextContinuationToken: "next", onRequest: requests.record) + [
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>", onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"], onRequest: requests.record),
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: "<DeleteResult/>", onRequest: requests.record)
			]

			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }
			#expect(requests.requests.map(\.httpMethod) == ["GET", "PUT", "POST", "GET", "PUT", "POST"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// A failed copy means that the target is incomplete, so a refusal before it doesn't make the move complete.
		@Test
		func moveFolderWithRefusalThenCopyFailureThrowsCopyError() async throws {
			let requests = RequestRecorder()
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(keys: ["folder/a.txt"], nextContinuationToken: "next", onRequest: requests.record) + [
				S3CloudProviderTests.copyObject(requests),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "AccessDenied")]), onRequest: requests.record),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"], onRequest: requests.record),
				URLProtocolMock.handler(statusCode: 400, body: "<Error><Code>InvalidRequest</Code></Error>", onRequest: requests.record)
			]

			let error = try await #require(throws: (any Error).self) { try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }
			#expect((error as? S3Error)?.code == "InvalidRequest", "Unexpected error: \(error)")
			#expect(requests.requests.map(\.httpMethod) == ["GET", "PUT", "POST", "GET", "PUT"])
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Whether the batch was deleted is unknown after a transport failure, so the move stops before the next page.
		@Test
		func moveFolderWithTransportFailureDuringBatchResendThrowsAtOnce() async throws {
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(keys: ["folder/a.txt"], nextContinuationToken: "next") + [
				URLProtocolMock.handler(body: S3MockResponse.copyObjectResult),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "SlowDown")]))
			] + Array(repeating: S3MockResponse.failure(.networkConnectionLost), count: 3) + [
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"])
			]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func moveFolderWithTransportFailureOnDeleteRequestThrowsAtOnce() async throws {
			URLProtocolMock.requestHandler = S3CloudProviderTests.folderMoveChecks(keys: ["folder/a.txt"], nextContinuationToken: "next") + [
				URLProtocolMock.handler(body: S3MockResponse.copyObjectResult),
				URLProtocolMock.handler(body: S3MockResponse.deleteResult(errors: [("folder/a.txt", "AccessDenied")])),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/b.txt"], nextContinuationToken: "next2"),
				URLProtocolMock.handler(body: S3MockResponse.copyObjectResult),
				S3MockResponse.failure(.notConnectedToInternet),
				S3CloudProviderTests.listing(of: "folder/", recursive: true, keys: ["folder/c.txt"])
			]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.moveFolder(from: CloudPath("/folder"), to: CloudPath("/target")) }
			#expect(URLProtocolMock.requestHandler.count == 1)
		}

		@Test
		func moveFileWithRefusedSourceDeleteThrowsMoveCompleted() async throws {
			URLProtocolMock.requestHandler = S3CloudProviderTests.fileMoveChecksAndCopy() + [
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>")
			]

			await #expect(throws: CloudProviderError.moveCompletedWithSourceRemaining) { try await provider.moveFile(from: CloudPath("/a.txt"), to: CloudPath("/b.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// The error body of a 404 may be missing, so any 404 means that the source is gone.
		@Test
		func moveFileWithNoSuchKeyOnSourceDeleteSucceeds() async throws {
			for body in ["<Error><Code>NoSuchKey</Code></Error>", ""] {
				URLProtocolMock.requestHandler = S3CloudProviderTests.fileMoveChecksAndCopy() + [
					URLProtocolMock.handler(statusCode: 404, body: body)
				]

				try await provider.moveFile(from: CloudPath("/a.txt"), to: CloudPath("/b.txt"))

				#expect(URLProtocolMock.requestHandler.isEmpty, "\(body)")
			}
		}

		/// The listing before the DELETE succeeded with the same credentials, so a 403 refuses this object rather than the login.
		@Test
		func deleteFileWithRefusedDeleteThrowsDeletionIncomplete() async throws {
			URLProtocolMock.requestHandler = [
				S3CloudProviderTests.listing(of: "a.txt", keys: ["a.txt"]),
				URLProtocolMock.handler(statusCode: 403, body: "<Error><Code>AccessDenied</Code></Error>")
			]

			await #expect(throws: CloudProviderError.deletionIncomplete) { try await provider.deleteFile(at: CloudPath("/a.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		/// Whether the source was deleted is unknown after a transport failure, so it doesn't count as a refusal.
		@Test
		func moveFileWithTransportFailureOnSourceDeleteKeepsError() async throws {
			URLProtocolMock.requestHandler = S3CloudProviderTests.fileMoveChecksAndCopy() + [
				S3MockResponse.failure(.notConnectedToInternet)
			]

			await #expect(throws: CloudProviderError.noInternetConnection) { try await provider.moveFile(from: CloudPath("/a.txt"), to: CloudPath("/b.txt")) }
			#expect(URLProtocolMock.requestHandler.isEmpty)
		}

		// MARK: - Helpers

		/// The responses to the checks and the copy of a file move from `/a.txt` to `/b.txt`.
		private static func fileMoveChecksAndCopy() -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [
				listing(of: "a.txt", keys: ["a.txt"]),
				listing(of: "b.txt"),
				URLProtocolMock.handler(body: S3MockResponse.copyObjectResult)
			]
		}

		/// The responses of a mutation whose check is answered by `check`, whose first write attempt fails with 503 and cancels the task, and whose retries are answered by `retries`.
		private static func cancellingFirstWrite(after check: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?), retries: [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]) -> (TaskCanceller<Void>) -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return { canceller in
				[check, URLProtocolMock.handler(statusCode: 503, onRequest: { _ in canceller.cancel() })] + retries
			}
		}

		/// Answers like `listing(of:recursive:body:onRequest:)` with a `ListBucketResult` of the keys, common prefixes and continuation token.
		private static func listing(of prefix: String, recursive: Bool = false, keys: [String] = [], commonPrefixes: [String] = [], nextContinuationToken: String? = nil, onRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
			return listing(of: prefix, recursive: recursive, body: S3MockResponse.listBucketResult(keys: keys, commonPrefixes: commonPrefixes, nextContinuationToken: nextContinuationToken), onRequest: onRequest)
		}

		/// Answers a `GET` with this `prefix` parameter and the listing's `delimiter` (none if `recursive`, `/` otherwise) with the body. It fails any other request, so that a check of another path or a listing of the other kind fails the test.
		private static func listing(of prefix: String, recursive: Bool = false, body: String, onRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
			let response = URLProtocolMock.handler(body: body, onRequest: onRequest)
			return { request in
				let parameters = queryParameters(of: request)
				let expectedDelimiter: String? = recursive ? nil : "/"
				guard request.httpMethod == "GET", parameters["prefix"] == prefix, parameters["delimiter"] == expectedDelimiter else {
					throw URLProtocolMockError.unexpectedRequest
				}
				return try response(request)
			}
		}

		private static func queryParameters(of request: URLRequest) -> [String: String] {
			let queryItems = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
			return Dictionary(queryItems.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
		}

		/// The responses to the checks of a folder move from `/folder` to `/target`: the first page of the source's recursive listing, which shows that it is a folder, and the target's lookup, which finds nothing.
		private static func folderMoveChecks(keys: [String], nextContinuationToken: String? = nil, onRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return folderMoveChecks(firstPageBody: S3MockResponse.listBucketResult(keys: keys, nextContinuationToken: nextContinuationToken), onRequest: onRequest)
		}

		/// The checks of `folderMoveChecks(keys:nextContinuationToken:onRequest:)`, with the body of the source's first page as it is.
		private static func folderMoveChecks(firstPageBody: String, onRequest: @escaping @Sendable (URLRequest) -> Void = { _ in }) -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)] {
			return [listing(of: "folder/", recursive: true, body: firstPageBody, onRequest: onRequest), listing(of: "target")]
		}

		private static func copyObject(_ requests: RequestRecorder) -> @Sendable (URLRequest) throws -> (HTTPURLResponse, Data?) {
			return URLProtocolMock.handler(body: S3MockResponse.copyObjectResult, onRequest: requests.record)
		}

		/// The copy source of each copy request by the path of its target. The copies of a page run concurrently, so their order isn't fixed.
		private static func copySources(of requests: ArraySlice<URLRequest>) -> [String: String] {
			let copies = requests.map { request in
				let targetPath = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath } ?? ""
				let copySource = request.value(forHTTPHeaderField: "x-amz-copy-source") ?? ""
				return (targetPath, copySource)
			}
			return Dictionary(copies, uniquingKeysWith: { first, _ in first })
		}

		private static func deletedKeys(of request: URLRequest) -> [String] {
			return S3XMLElement.parse(request.httpBody ?? Data())?.children("Object").compactMap { $0.text(of: "Key") } ?? []
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
		private func assertAborted(_ requests: RequestRecorder, attempts: Int = 1, temporaryFiles: Set<String>, sourceLocation: SourceLocation = #_sourceLocation) throws {
			let aborts = requests.requests
			#expect(Array(repeating: "DELETE", count: attempts) == aborts.map(\.httpMethod), sourceLocation: sourceLocation)
			#expect(Array(repeating: ["uploadId": "upload-id"], count: attempts) == aborts.map(S3CloudProviderTests.queryParameters(of:)), sourceLocation: sourceLocation)
			#expect(URLProtocolMock.requestHandler.isEmpty, sourceLocation: sourceLocation)
			#expect(try temporaryFiles == uuidNamedTemporaryFiles(), sourceLocation: sourceLocation)
		}

		/// A sparse file one byte larger than the largest part, which a provider with `maxPartCount` 1 can't upload.
		private func makeFileOverMaximumSize() throws -> URL {
			let localURL = tmpDirURL.appendingPathComponent("sparse.bin")
			#expect(FileManager.default.createFile(atPath: localURL.path, contents: nil))
			try FileHandle(forWritingTo: localURL).truncate(atOffset: UInt64(S3Client.maxPartSize + 1))
			return localURL
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
}

/// A mutation whose task the handler of one of its requests cancels.
private struct CancelledMutationCase {
	let name: String
	let responses: (TaskCanceller<Void>) -> [@Sendable (URLRequest) throws -> (HTTPURLResponse, Data?)]
	let operation: @Sendable (S3CloudProvider) async throws -> Void
	let remainingResponses: Int
	var isExpected: (Error?) -> Bool = { $0 is CancellationError }
}

extension S3Credential {
	static let stub = S3Credential(accessKey: "access", secretKey: "secret", url: URL(string: "https://www.example.com")!, bucket: "exampleBucket", region: "example-region", identifier: UUID().uuidString)
}
