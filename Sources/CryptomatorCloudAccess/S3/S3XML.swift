//
//  S3XML.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 18.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

struct S3Object: Equatable {
	let key: String
	let lastModified: Date?
	let size: Int?
}

typealias S3CompletedPart = (partNumber: Int, eTag: String)

struct S3ListObjectsResult: Equatable {
	let contents: [S3Object]
	let commonPrefixes: [String]
	let nextContinuationToken: String?

	init(contents: [S3Object], commonPrefixes: [String], nextContinuationToken: String?) {
		self.contents = contents
		self.commonPrefixes = commonPrefixes
		self.nextContinuationToken = nextContinuationToken
	}

	/// - Throws: `S3ResponseError.unparseableResult` if the body is no `ListBucketResult` document.
	init(xml body: Data) throws {
		guard let root = S3XMLElement.parse(body), root.name == "ListBucketResult" else {
			throw S3ResponseError.unparseableResult
		}
		self.contents = root.children("Contents").compactMap { content in
			guard let key = content.text(of: "Key") else {
				return nil
			}
			return S3Object(key: key, lastModified: content.text(of: "LastModified").flatMap(S3XML.date(from:)), size: content.text(of: "Size").flatMap { Int($0) })
		}
		self.commonPrefixes = root.children("CommonPrefixes").compactMap { $0.text(of: "Prefix") }
		self.nextContinuationToken = root.text(of: "NextContinuationToken")
	}
}

enum S3XML {
	private static let namespace = "http://s3.amazonaws.com/doc/2006-03-01/"

	// The formatters are never mutated after their creation, which makes them safe to share across threads.
	private nonisolated(unsafe) static let formatter = ISO8601DateFormatter()
	private nonisolated(unsafe) static let fractionalSecondsFormatter = {
		let formatter = ISO8601DateFormatter()
		formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return formatter
	}()

	static func date(from string: String) -> Date? {
		return fractionalSecondsFormatter.date(from: string) ?? formatter.date(from: string)
	}

	// MARK: - Results

	/// - Throws: `S3ResponseError.unparseableResult` if the body is no `InitiateMultipartUploadResult` with an upload ID.
	static func uploadID(in body: Data) throws -> String {
		guard let root = S3XMLElement.parse(body), root.name == "InitiateMultipartUploadResult", let uploadID = root.text(of: "UploadId") else {
			throw S3ResponseError.unparseableResult
		}
		return uploadID
	}

	/// Returns the ETag of a `CopyObjectResult` or `CopyPartResult`.
	/// - Throws: `S3ResponseError.unparseableResult` if the body has no ETag, e.g., because S3 cut a long-running copy short.
	static func copyETag(in body: Data) throws -> String {
		guard let root = S3XMLElement.parse(body), ["CopyObjectResult", "CopyPartResult"].contains(root.name), let eTag = root.text(of: "ETag") else {
			throw S3ResponseError.unparseableResult
		}
		return eTag
	}

	/// - Throws: `S3ResponseError.unparseableResult` if the body is no `CompleteMultipartUploadResult`.
	static func validateCompleteMultipartUploadResult(_ body: Data) throws {
		guard S3XMLElement.rootName(of: body) == "CompleteMultipartUploadResult" else {
			throw S3ResponseError.unparseableResult
		}
	}

	// MARK: - Request Bodies

	static func deleteObjectsBody(keys: [String]) -> Data {
		let objects = keys.map { "<Object><Key>\(escaped($0))</Key></Object>" }.joined()
		return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Delete xmlns=\"\(namespace)\"><Quiet>true</Quiet>\(objects)</Delete>".utf8)
	}

	static func completeMultipartUploadBody(parts: [S3CompletedPart]) -> Data {
		let parts = parts.map { "<Part><PartNumber>\($0.partNumber)</PartNumber><ETag>\(escaped($0.eTag))</ETag></Part>" }.joined()
		return Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><CompleteMultipartUpload xmlns=\"\(namespace)\">\(parts)</CompleteMultipartUpload>".utf8)
	}

	private static func escaped(_ text: String) -> String {
		return text
			.replacingOccurrences(of: "&", with: "&amp;")
			.replacingOccurrences(of: "<", with: "&lt;")
			.replacingOccurrences(of: ">", with: "&gt;")
			.replacingOccurrences(of: "\"", with: "&quot;")
			.replacingOccurrences(of: "'", with: "&apos;")
	}
}

/// An element of an S3 XML document with its text and child elements. Names are local names without a namespace.
struct S3XMLElement {
	let name: String
	fileprivate(set) var text = ""
	fileprivate(set) var children = [S3XMLElement]()

	func child(_ name: String) -> S3XMLElement? {
		return children.first { $0.name == name }
	}

	func children(_ name: String) -> [S3XMLElement] {
		return children.filter { $0.name == name }
	}

	func text(of childName: String) -> String? {
		return child(childName)?.text
	}

	static func parse(_ body: Data) -> S3XMLElement? {
		return S3XMLTreeBuilder.parse(body, stopsAtRoot: false)
	}

	/// Returns the name of the root element without parsing the rest of the document.
	static func rootName(of body: Data) -> String? {
		return S3XMLTreeBuilder.parse(body, stopsAtRoot: true)?.name
	}
}

private final class S3XMLTreeBuilder: NSObject, XMLParserDelegate {
	private let stopsAtRoot: Bool
	private var openElements = [S3XMLElement]()
	private var root: S3XMLElement?

	private init(stopsAtRoot: Bool) {
		self.stopsAtRoot = stopsAtRoot
	}

	/// S3 sends whitespace before the XML declaration to keep the connection of a long-running copy alive. `XMLParser` rejects leading whitespace, so it is dropped.
	static func parse(_ body: Data, stopsAtRoot: Bool) -> S3XMLElement? {
		let document = Data(body.drop(while: { [0x20, 0x09, 0x0A, 0x0D].contains($0) }))
		let parser = XMLParser(data: document)
		parser.shouldProcessNamespaces = true
		let builder = S3XMLTreeBuilder(stopsAtRoot: stopsAtRoot)
		parser.delegate = builder
		guard parser.parse() || builder.stopsAtRoot else {
			return nil
		}
		return builder.root
	}

	// MARK: - XMLParserDelegate

	func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
		if stopsAtRoot {
			root = S3XMLElement(name: elementName)
			parser.abortParsing()
			return
		}
		openElements.append(S3XMLElement(name: elementName))
	}

	func parser(_ parser: XMLParser, foundCharacters string: String) {
		guard !openElements.isEmpty else {
			return
		}
		openElements[openElements.count - 1].text += string
	}

	func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
		guard let element = openElements.popLast() else {
			return
		}
		if openElements.isEmpty {
			root = element
		} else {
			openElements[openElements.count - 1].children.append(element)
		}
	}
}
