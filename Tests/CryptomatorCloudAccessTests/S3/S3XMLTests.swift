//
//  S3XMLTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct S3XMLTests {
		@Test
		func listObjectsResult() throws {
			let body = Data("""
			<?xml version="1.0" encoding="UTF-8"?>
			<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
				<Name>mybucket</Name>
				<Prefix>folder/</Prefix>
				<KeyCount>3</KeyCount>
				<MaxKeys>1000</MaxKeys>
				<Delimiter>/</Delimiter>
				<IsTruncated>true</IsTruncated>
				<NextContinuationToken>a+b/c=</NextContinuationToken>
				<Contents><Key>folder/a &amp; b.txt</Key><LastModified>2026-10-18T12:34:56.500Z</LastModified><Size>42</Size></Contents>
				<Contents><Key>folder/c.txt</Key><LastModified>2026-10-18T12:34:56Z</LastModified><Size>0</Size></Contents>
				<CommonPrefixes><Prefix>folder/sub/</Prefix></CommonPrefixes>
			</ListBucketResult>
			""".utf8)

			let result = try S3ListObjectsResult(xml: body)

			#expect([
				S3Object(key: "folder/a & b.txt", lastModified: "2026-10-18T12:34:56.500Z", size: 42),
				S3Object(key: "folder/c.txt", lastModified: "2026-10-18T12:34:56Z", size: 0)
			] == result.contents)
			#expect(result.commonPrefixes == ["folder/sub/"])
			#expect(result.nextContinuationToken == "a+b/c=")
		}

		@Test
		func listObjectsResultWithoutNextPage() throws {
			let result = try S3ListObjectsResult(xml: Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
			#expect(S3ListObjectsResult(contents: [], commonPrefixes: [], nextContinuationToken: nil) == result)
			#expect(try S3ListObjectsResult(xml: Data("<ListBucketResult><IsTruncated>false</IsTruncated><NextContinuationToken>next</NextContinuationToken></ListBucketResult>".utf8)).nextContinuationToken == nil)
			#expect(try S3ListObjectsResult(xml: Data("<ListBucketResult><NextContinuationToken/></ListBucketResult>".utf8)).nextContinuationToken == nil)
		}

		@Test
		func truncatedListObjectsResultWithoutContinuationTokenIsUnparseable() {
			for body in ["<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken/></ListBucketResult>", "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"] {
				#expect(throws: S3ResponseError.unparseableResult) { try S3ListObjectsResult(xml: Data(body.utf8)) }
			}
		}

		@Test
		func errorResponse() {
			let body = Data("""
			<?xml version="1.0" encoding="UTF-8"?>
			<Error><Code>InvalidArgument</Code><Message>Invalid continuation token</Message><ArgumentName>continuation-token</ArgumentName><ArgumentValue>foo</ArgumentValue><Reason>Incorrect padding</Reason><RequestId>1</RequestId></Error>
			""".utf8)

			#expect(S3Error(statusCode: 400, code: "InvalidArgument", message: "Invalid continuation token", argumentName: "continuation-token", reason: "Incorrect padding") == S3Error(statusCode: 400, body: body))
		}

		@Test
		func errorResponseWithoutXMLHasOnlyStatus() {
			#expect(S3Error(statusCode: 503) == S3Error(statusCode: 503, body: Data("Service Unavailable".utf8)))
			#expect(S3Error(statusCode: 404) == S3Error(statusCode: 404, body: Data()))
		}

		@Test
		func errorTakesBucketRegionFromHeaderOverDocument() {
			let body = Data("<Error><Code>AuthorizationHeaderMalformed</Code><Region>eu-west-1</Region></Error>".utf8)

			#expect(S3Error(statusCode: 400, body: body, bucketRegionHeader: "eu-central-1").bucketRegion == "eu-central-1")
			#expect(S3Error(statusCode: 400, body: body).bucketRegion == "eu-west-1")
			#expect(S3Error(statusCode: 400, body: body, bucketRegionHeader: "eu-west-1/x").bucketRegion == "eu-west-1")
			#expect(S3Error(statusCode: 301, body: Data(), bucketRegionHeader: "eu-central-1").bucketRegion == "eu-central-1")
		}

		/// A region goes into the signing scope and possibly the host, so one that fails the region rule is dropped.
		@Test
		func errorDropsInvalidBucketRegion() {
			for region in ["eu-west-1/x", "", "-eu-west-1", "eu.west.1"] {
				let body = Data("<Error><Code>AuthorizationHeaderMalformed</Code><Region>\(region)</Region></Error>".utf8)
				#expect(S3Error(statusCode: 400, body: body, bucketRegionHeader: region).bucketRegion == nil, "\(region)")
				#expect(S3Error(statusCode: 301, body: Data(), bucketRegionHeader: region).bucketRegion == nil, "\(region)")
			}
		}

		@Test
		func testIsWrongRegion() {
			#expect(S3Error(statusCode: 301).isWrongRegion)
			for code in ["PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException"] {
				#expect(S3Error(statusCode: 400, code: code).isWrongRegion, "\(code)")
			}
			#expect(!S3Error(statusCode: 403, code: "AccessDenied").isWrongRegion)
			#expect(!S3Error(statusCode: 400).isWrongRegion)
		}

		@Test
		func errorDocumentInSuccessfulResponseIsDetected() {
			let body = Data("<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>".utf8)
			#expect(S3Error(errorDocument: body, statusCode: 200)?.code == "InternalError")
			#expect(S3Error(errorDocument: Data("<CopyObjectResult><ETag>\"etag\"</ETag></CopyObjectResult>".utf8), statusCode: 200) == nil)
		}

		/// S3 sends whitespace before the XML declaration to keep the connection of a long-running copy alive.
		@Test
		func whitespacePrefixedDocumentsParse() throws {
			let completeResult = Data("   \n<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUploadResult><ETag>\"etag-3\"</ETag></CompleteMultipartUploadResult>".utf8)
			let error = Data("   \n<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>InternalError</Code></Error>".utf8)

			#expect(throws: Never.self) { try S3XML.validateCompleteMultipartUploadResult(completeResult) }
			#expect(S3Error(errorDocument: error, statusCode: 200)?.code == "InternalError")
		}

		@Test
		func copyETagOfIncompleteResultThrows() {
			#expect(throws: S3ResponseError.unparseableResult) { try S3XML.copyETag(in: Data("     ".utf8)) }
		}

		@Test
		func errorDescriptionOmitsSigningDetails() {
			let body = Data("""
			<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided.</Message><AWSAccessKeyId>ACCESSKEYID</AWSAccessKeyId><StringToSign>STRINGTOSIGN</StringToSign><SignatureProvided>SIGNATUREPROVIDED</SignatureProvided><CanonicalRequest>CANONICALREQUEST</CanonicalRequest><HostId>HOSTID</HostId></Error>
			""".utf8)

			let description = S3Error(statusCode: 403, body: body).description

			#expect(description.contains("SignatureDoesNotMatch"))
			for value in ["ACCESSKEYID", "STRINGTOSIGN", "SIGNATUREPROVIDED", "CANONICALREQUEST", "HOSTID"] {
				#expect(!description.contains(value), "\(value) in \(description)")
			}
		}

		@Test
		func deletionFailuresOfResultWithoutErrors() throws {
			for body in ["", " \n\t\r", "<DeleteResult/>", "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<DeleteResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Deleted><Key>a.txt</Key></Deleted></DeleteResult>"] {
				#expect(try S3XML.deletionFailures(in: Data(body.utf8)) == [], "\(body)")
			}
		}

		@Test
		func testDeletionFailures() throws {
			let body = Data("""
			<?xml version="1.0" encoding="UTF-8"?>
			<DeleteResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
				<Error><Key>a &amp; b.txt</Key><Code>AccessDenied</Code><Message>Access Denied</Message></Error>
				<Error><Key>c&#10;d.txt</Key><Code>InternalError</Code></Error>
				<Error><Code>AccessDenied</Code></Error>
			</DeleteResult>
			""".utf8)

			#expect(try [
				S3DeletionFailure(key: "a & b.txt", code: "AccessDenied"),
				S3DeletionFailure(key: "c\nd.txt", code: "InternalError"),
				S3DeletionFailure(key: nil, code: "AccessDenied")
			] == S3XML.deletionFailures(in: body))
		}

		@Test
		func deletionFailuresOfOtherDocumentThrows() {
			#expect(throws: S3ResponseError.unparseableResult) { try S3XML.deletionFailures(in: Data(S3MockResponse.copyObjectResult.utf8)) }
		}

		@Test
		func deleteObjectsBodyEscapesKeys() throws {
			let body = try #require(String(bytes: S3XML.deleteObjectsBody(keys: ["a<b>&c.txt"]), encoding: .utf8))
			#expect(body.contains("<Quiet>true</Quiet><Object><Key>a&lt;b&gt;&amp;c.txt</Key></Object>"), "\(body)")
		}

		@Test
		func deleteObjectsBodyPreservesLineBreaksInKeys() throws {
			let keys = ["a\rb.txt", "a\r\nb.txt", "a\nb.txt"]
			let root = try #require(S3XMLElement.parse(S3XML.deleteObjectsBody(keys: keys)))
			#expect(keys == root.children("Object").compactMap { $0.text(of: "Key") })
		}
	}
}
