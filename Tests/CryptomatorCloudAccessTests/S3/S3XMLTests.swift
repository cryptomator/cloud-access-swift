//
//  S3XMLTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class S3XMLTests: XCTestCase {
	func testListObjectsResult() throws {
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

		XCTAssertEqual([
			S3Object(key: "folder/a & b.txt", lastModified: "2026-10-18T12:34:56.500Z", size: 42),
			S3Object(key: "folder/c.txt", lastModified: "2026-10-18T12:34:56Z", size: 0)
		], result.contents)
		XCTAssertEqual(["folder/sub/"], result.commonPrefixes)
		XCTAssertEqual("a+b/c=", result.nextContinuationToken)
	}

	func testListObjectsResultWithoutNextPage() throws {
		let result = try S3ListObjectsResult(xml: Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
		XCTAssertEqual(S3ListObjectsResult(contents: [], commonPrefixes: [], nextContinuationToken: nil), result)
		XCTAssertNil(try S3ListObjectsResult(xml: Data("<ListBucketResult><IsTruncated>false</IsTruncated><NextContinuationToken>next</NextContinuationToken></ListBucketResult>".utf8)).nextContinuationToken)
		XCTAssertNil(try S3ListObjectsResult(xml: Data("<ListBucketResult><NextContinuationToken/></ListBucketResult>".utf8)).nextContinuationToken)
	}

	func testTruncatedListObjectsResultWithoutContinuationTokenIsUnparseable() {
		for body in ["<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken/></ListBucketResult>", "<ListBucketResult><IsTruncated>true</IsTruncated></ListBucketResult>"] {
			XCTAssertThrowsError(try S3ListObjectsResult(xml: Data(body.utf8))) { error in
				guard case S3ResponseError.unparseableResult = error else {
					return XCTFail("Expected unparseableResult, got \(error)")
				}
			}
		}
	}

	func testErrorResponse() {
		let body = Data("""
		<?xml version="1.0" encoding="UTF-8"?>
		<Error><Code>InvalidArgument</Code><Message>Invalid continuation token</Message><ArgumentName>continuation-token</ArgumentName><ArgumentValue>foo</ArgumentValue><Reason>Incorrect padding</Reason><RequestId>1</RequestId></Error>
		""".utf8)

		XCTAssertEqual(S3Error(statusCode: 400, code: "InvalidArgument", message: "Invalid continuation token", argumentName: "continuation-token", reason: "Incorrect padding"), S3Error(statusCode: 400, body: body))
	}

	func testErrorResponseWithoutXMLHasOnlyStatus() {
		XCTAssertEqual(S3Error(statusCode: 503), S3Error(statusCode: 503, body: Data("Service Unavailable".utf8)))
		XCTAssertEqual(S3Error(statusCode: 404), S3Error(statusCode: 404, body: Data()))
	}

	func testErrorTakesBucketRegionFromHeaderOverDocument() {
		let body = Data("<Error><Code>AuthorizationHeaderMalformed</Code><Region>eu-west-1</Region></Error>".utf8)

		XCTAssertEqual("eu-central-1", S3Error(statusCode: 400, body: body, bucketRegionHeader: "eu-central-1").bucketRegion)
		XCTAssertEqual("eu-west-1", S3Error(statusCode: 400, body: body).bucketRegion)
		XCTAssertEqual("eu-west-1", S3Error(statusCode: 400, body: body, bucketRegionHeader: "eu-west-1/x").bucketRegion)
		XCTAssertEqual("eu-central-1", S3Error(statusCode: 301, body: Data(), bucketRegionHeader: "eu-central-1").bucketRegion)
	}

	/// A region goes into the signing scope and possibly the host, so one that fails the region rule is dropped.
	func testErrorDropsInvalidBucketRegion() {
		for region in ["eu-west-1/x", "", "-eu-west-1", "eu.west.1"] {
			let body = Data("<Error><Code>AuthorizationHeaderMalformed</Code><Region>\(region)</Region></Error>".utf8)
			XCTAssertNil(S3Error(statusCode: 400, body: body, bucketRegionHeader: region).bucketRegion, region)
			XCTAssertNil(S3Error(statusCode: 301, body: Data(), bucketRegionHeader: region).bucketRegion, region)
		}
	}

	func testIsWrongRegion() {
		XCTAssertTrue(S3Error(statusCode: 301).isWrongRegion)
		for code in ["PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException"] {
			XCTAssertTrue(S3Error(statusCode: 400, code: code).isWrongRegion, code)
		}
		XCTAssertFalse(S3Error(statusCode: 403, code: "AccessDenied").isWrongRegion)
		XCTAssertFalse(S3Error(statusCode: 400).isWrongRegion)
	}

	func testErrorDocumentInSuccessfulResponseIsDetected() {
		let body = Data("<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>".utf8)
		XCTAssertEqual("InternalError", S3Error(errorDocument: body, statusCode: 200)?.code)
		XCTAssertNil(S3Error(errorDocument: Data("<CopyObjectResult><ETag>\"etag\"</ETag></CopyObjectResult>".utf8), statusCode: 200))
	}

	/// S3 sends whitespace before the XML declaration to keep the connection of a long-running copy alive.
	func testWhitespacePrefixedDocumentsParse() throws {
		let completeResult = Data("   \n<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUploadResult><ETag>\"etag-3\"</ETag></CompleteMultipartUploadResult>".utf8)
		let error = Data("   \n<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>InternalError</Code></Error>".utf8)

		XCTAssertNoThrow(try S3XML.validateCompleteMultipartUploadResult(completeResult))
		XCTAssertEqual("InternalError", S3Error(errorDocument: error, statusCode: 200)?.code)
	}

	func testCopyETagOfIncompleteResultThrows() {
		XCTAssertThrowsError(try S3XML.copyETag(in: Data("     ".utf8))) { error in
			XCTAssertEqual(.unparseableResult, error as? S3ResponseError)
		}
	}

	func testErrorDescriptionOmitsSigningDetails() {
		let body = Data("""
		<Error><Code>SignatureDoesNotMatch</Code><Message>The request signature we calculated does not match the signature you provided.</Message><AWSAccessKeyId>ACCESSKEYID</AWSAccessKeyId><StringToSign>STRINGTOSIGN</StringToSign><SignatureProvided>SIGNATUREPROVIDED</SignatureProvided><CanonicalRequest>CANONICALREQUEST</CanonicalRequest><HostId>HOSTID</HostId></Error>
		""".utf8)

		let description = S3Error(statusCode: 403, body: body).description

		XCTAssertTrue(description.contains("SignatureDoesNotMatch"))
		for value in ["ACCESSKEYID", "STRINGTOSIGN", "SIGNATUREPROVIDED", "CANONICALREQUEST", "HOSTID"] {
			XCTAssertFalse(description.contains(value), "\(value) in \(description)")
		}
	}

	func testDeleteObjectsBodyEscapesKeys() throws {
		let body = try XCTUnwrap(String(bytes: S3XML.deleteObjectsBody(keys: ["a<b>&c.txt"]), encoding: .utf8))
		XCTAssertTrue(body.contains("<Quiet>true</Quiet><Object><Key>a&lt;b&gt;&amp;c.txt</Key></Object>"), body)
	}

	func testDeleteObjectsBodyPreservesLineBreaksInKeys() throws {
		let keys = ["a\rb.txt", "a\r\nb.txt", "a\nb.txt"]
		let root = try XCTUnwrap(S3XMLElement.parse(S3XML.deleteObjectsBody(keys: keys)))
		XCTAssertEqual(keys, root.children("Object").compactMap { $0.text(of: "Key") })
	}
}
