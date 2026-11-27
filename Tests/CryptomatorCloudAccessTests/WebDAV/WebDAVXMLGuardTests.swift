//
//  WebDAVXMLGuardTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import CryptomatorCloudAccessTestSupport
import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class WebDAVXMLGuardTests {
		private static let chunkSizes = [1, 2, 3, HTTPClientSupport.temporaryFileBufferLength]
		private static let fileChunkSizes = [7, HTTPClientSupport.temporaryFileBufferLength]

		private let tmpDirURL: URL

		init() throws {
			self.tmpDirURL = try makeTemporaryDirectory()
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Compatibility

		@Test
		func fixturesPass() throws {
			let fixtureURLs = try #require(Bundle.module.urls(forResourcesWithExtension: "xml", subdirectory: nil))
			#expect(!fixtureURLs.isEmpty)
			for fixtureURL in fixtureURLs {
				try assertAccepts(Data(contentsOf: fixtureURL), fixtureURL.lastPathComponent)
			}
		}

		@Test
		func everyPrefixOfListingPasses() throws {
			let listing = try fixture("item-list")
			for length in 0 ... listing.count {
				#expect(throws: Never.self, "\(length)") { try self.scan(listing.prefix(length), chunkSize: 3) }
			}
		}

		// MARK: - Caps

		@Test
		func startTagAtCapPasses() {
			func body(tagLength: Int) -> String {
				return "<a x=\"" + String(repeating: "v", count: tagLength - "<a x=\"\">".count) + "\"></a>"
			}
			assertCapPair(.tag, body(tagLength: WebDAVXMLLimits.maxTagLength), body(tagLength: WebDAVXMLLimits.maxTagLength + 1))
		}

		@Test
		func endTagAtCapPasses() {
			func body(tagLength: Int) -> String {
				return "<a></a" + String(repeating: " ", count: tagLength - "</a>".count) + ">"
			}
			assertCapPair(.tag, body(tagLength: WebDAVXMLLimits.maxTagLength), body(tagLength: WebDAVXMLLimits.maxTagLength + 1))
		}

		/// Namespace declarations count as attributes, and either quote opens a value.
		@Test
		func attributesAtCapPass() {
			func body(attributeCount: Int) -> String {
				let attributes = (0 ..< attributeCount).map { $0.isMultiple(of: 2) ? "xmlns:p\($0)=\"urn:\($0)\"" : "a\($0)='v'" }
				return "<a " + attributes.joined(separator: " ") + "/>"
			}
			assertCapPair(.attributes, body(attributeCount: WebDAVXMLLimits.maxAttributeCount), body(attributeCount: WebDAVXMLLimits.maxAttributeCount + 1))
		}

		@Test
		func commentAtCapPasses() {
			func body(contentLength: Int) -> String {
				return "<a><!--" + String(repeating: "c", count: contentLength) + "--></a>"
			}
			assertCapPair(.comment, body(contentLength: WebDAVXMLLimits.maxDelimitedLength), body(contentLength: WebDAVXMLLimits.maxDelimitedLength + 1))
		}

		/// A byte that can't belong to the closing delimiter counts as content as soon as it arrives, before any `-->`.
		@Test
		func unclosedCommentOverCapThrows() {
			assertThrows(.limitExceeded(.comment), Data(("<a><!--" + String(repeating: "c", count: WebDAVXMLLimits.maxDelimitedLength + 1)).utf8))
		}

		@Test
		func cdataSectionAtCapPasses() {
			func body(contentLength: Int) -> String {
				return "<a><![CDATA[" + String(repeating: "c", count: contentLength) + "]]></a>"
			}
			assertCapPair(.cdata, body(contentLength: WebDAVXMLLimits.maxDelimitedLength), body(contentLength: WebDAVXMLLimits.maxDelimitedLength + 1))
		}

		/// The surplus `]` belongs to the content, so it is the byte that crosses the cap.
		@Test
		func cdataSectionWithSurplusBracketAtCapPasses() {
			func body(contentLength: Int) -> String {
				return "<a><![CDATA[" + String(repeating: "c", count: contentLength - 1) + "]]]></a>"
			}
			assertCapPair(.cdata, body(contentLength: WebDAVXMLLimits.maxDelimitedLength), body(contentLength: WebDAVXMLLimits.maxDelimitedLength + 1))
		}

		/// The target and the whitespace after it count as content.
		@Test
		func processingInstructionAtCapPasses() {
			func body(contentLength: Int) -> String {
				return "<a><?pi " + String(repeating: "c", count: contentLength - "pi ".count) + "?></a>"
			}
			assertCapPair(.processingInstruction, body(contentLength: WebDAVXMLLimits.maxDelimitedLength), body(contentLength: WebDAVXMLLimits.maxDelimitedLength + 1))
		}

		@Test
		func processingInstructionWithSurplusQuestionMarkAtCapPasses() {
			func body(contentLength: Int) -> String {
				return "<a><?pi " + String(repeating: "c", count: contentLength - "pi ?".count) + "??></a>"
			}
			assertCapPair(.processingInstruction, body(contentLength: WebDAVXMLLimits.maxDelimitedLength), body(contentLength: WebDAVXMLLimits.maxDelimitedLength + 1))
		}

		@Test
		func xmlDeclarationAtProcessingInstructionCapPasses() {
			func body(contentLength: Int) -> String {
				let head = "xml version=\"1.0\" encoding=\"UTF-8\""
				return "<?" + head + String(repeating: " ", count: contentLength - head.count) + "?><a/>"
			}
			assertCapPair(.processingInstruction, body(contentLength: WebDAVXMLLimits.maxDelimitedLength), body(contentLength: WebDAVXMLLimits.maxDelimitedLength + 1))
		}

		/// A character reference may have leading zeros, which libxml2 buffers with the reference.
		@Test
		func referenceAtCapPasses() {
			func body(referenceLength: Int) -> String {
				return "<a>x&#" + String(repeating: "0", count: referenceLength - "#65".count) + "65;y</a>"
			}
			assertCapPair(.reference, body(referenceLength: WebDAVXMLLimits.maxReferenceLength), body(referenceLength: WebDAVXMLLimits.maxReferenceLength + 1))
		}

		/// libxml2 waits for the `;` of a reference wherever it comes, so the markup before it counts.
		@Test
		func referenceCountsMarkupUpToSemicolon() {
			func body(referenceLength: Int) -> String {
				return "<r>&<a/>" + String(repeating: "b", count: referenceLength - "<a/>".count) + ";</r>"
			}
			assertCapPair(.reference, body(referenceLength: WebDAVXMLLimits.maxReferenceLength), body(referenceLength: WebDAVXMLLimits.maxReferenceLength + 1))
		}

		/// With the root, `nameCount` distinct element names.
		@Test
		func distinctElementNamesAtCapPass() {
			func body(nameCount: Int) -> String {
				return "<r>" + (1 ..< nameCount).map { "<e\($0)></e\($0)>" }.joined() + "</r>"
			}
			assertCapPair(.names, body(nameCount: WebDAVXMLLimits.maxDistinctNames), body(nameCount: WebDAVXMLLimits.maxDistinctNames + 1))
		}

		/// Each declaration adds a distinct attribute name and a distinct namespace URI, and the root and `e` add 2 names.
		@Test
		func distinctNamespaceDeclarationsAtCapPass() {
			let declarationCount = (WebDAVXMLLimits.maxDistinctNames - 2) / 2
			let declarations = (0 ..< declarationCount).map { "<e xmlns:p\($0)=\"urn:\($0)\"/>" }.joined()
			let atCap = "<r>" + declarations + "</r>"
			let overCap = "<r>" + declarations + "<e xmlns:q=\"urn:0\"/></r>"
			assertCapPair(.names, atCap, overCap)
		}

		/// A default namespace declaration counts its URI too, and the root, `e` and `xmlns` add 3 names.
		@Test
		func distinctDefaultNamespaceURIsAtCapPass() {
			func body(uriCount: Int) -> String {
				return "<r>" + (0 ..< uriCount).map { "<e xmlns=\"urn:\($0)\"/>" }.joined() + "</r>"
			}
			assertCapPair(.names, body(uriCount: WebDAVXMLLimits.maxDistinctNames - 3), body(uriCount: WebDAVXMLLimits.maxDistinctNames - 2))
		}

		@Test
		func distinctProcessingInstructionTargetsAtCapPass() {
			func body(nameCount: Int) -> String {
				return "<r>" + (1 ..< nameCount).map { "<?t\($0)?>" }.joined() + "</r>"
			}
			assertCapPair(.names, body(nameCount: WebDAVXMLLimits.maxDistinctNames), body(nameCount: WebDAVXMLLimits.maxDistinctNames + 1))
		}

		@Test
		func repeatedNamesAndDistinctAttributeValuesDoNotCount() {
			let elements = (0 ... WebDAVXMLLimits.maxDistinctNames).map { "<e a=\"v\($0)\"></e>" }.joined()
			assertAccepts(Data(("<r>" + elements + "</r>").utf8))
		}

		/// The root `r` and 16 targets hold 256 KiB.
		@Test
		func distinctNamesAtLengthCapPass() {
			func body(lastTargetLength: Int) -> String {
				let targets = (0 ..< 15).map { String(repeating: Character(UnicodeScalar(UInt8(ascii: "a") + UInt8($0))), count: 16 * 1024) } + [String(repeating: "p", count: lastTargetLength)]
				return "<r>" + targets.map { "<?\($0)?>" }.joined() + "</r>"
			}
			assertCapPair(.names, body(lastTargetLength: 16 * 1024 - 1), body(lastTargetLength: 16 * 1024))
		}

		/// The guard counts bytes, so a character of several UTF-8 bytes counts each of them.
		@Test
		func commentOfMultibyteCharactersAtCapPasses() {
			func body(contentLength: Int) -> String {
				return "<a><!--" + String(repeating: "😀", count: contentLength / 4) + String(repeating: "c", count: contentLength % 4) + "--></a>"
			}
			assertCapPair(.comment, body(contentLength: WebDAVXMLLimits.maxDelimitedLength), body(contentLength: WebDAVXMLLimits.maxDelimitedLength + 1))
		}

		// MARK: - Delimiters

		/// Each start tag exceeds the tag cap only if no delimiter in its quoted value ended the value or the tag.
		@Test
		func delimitersInQuotedValuesDoNotEndTag() {
			let padding = String(repeating: "v", count: WebDAVXMLLimits.maxTagLength)
			for body in ["<r a=\">' ]]> --> ?>\(padding)\"/>", "<r a='\">\(padding)'/>"] {
				assertThrows(.limitExceeded(.tag), Data(body.utf8), String(body.prefix(20)))
			}
		}

		/// Each body hides a `<!DOCTYPE` that the guard would refuse if a `<` in it ended the comment or the CDATA section.
		@Test
		func markupInCommentsAndCDATASectionsDoesNotEndThem() {
			for body in ["<r><!-- < <!DOCTYPE r> --></r>", "<r><![CDATA[ < <!DOCTYPE r> ]]></r>"] {
				assertAccepts(Data(body.utf8), body)
			}
		}

		/// libxml2 finds a tag's `>` by a quote-aware scan from the last `<`, which a quote in an end tag or a `<` in a value would let run past the tag cap.
		@Test
		func misplacedTagDelimitersThrowUnsupportedTagDelimiter() {
			for body in ["<r></r '>", "<r></r \">", "<r a=\"<\"/>", "<r a='<'/>"] {
				assertThrows(.unsupported(.tagDelimiter), Data(body.utf8), body)
			}
		}

		/// Each body ends with a `<!DOCTYPE`, which the guard sees only if the construct before it ended.
		@Test
		func delimitersEndConstructs() {
			let bodies = [
				"<r>\"'</r><!DOCTYPE r>",
				"<r><![CDATA[x]]]></r><!DOCTYPE r>",
				"<r><?pi x??></r><!DOCTYPE r>",
				"<r><!--x--></r><!DOCTYPE r>"
			]
			for body in bodies {
				assertThrows(.unsupported(.doctype), Data(body.utf8), body)
			}
		}

		/// Before the root element, libxml2 reads `<![` as a start tag, whose wait for `>` the tag cap wouldn't bound. Within the root element, the section passes.
		@Test
		func cdataSectionBeforeRootElementThrowsUnsupportedDoctype() {
			for body in ["<![CDATA[x]]><r/>", "<?xml version=\"1.0\"?><!-- c --><![CDATA[x]]><r/>"] {
				assertThrows(.unsupported(.doctype), Data(body.utf8), body)
			}
			assertAccepts(Data("<?xml version=\"1.0\"?><r><![CDATA[x]]></r>".utf8))
		}

		/// libxml2 keeps the catalog that a catalog processing instruction names before the root element for the whole parse, and ignores one anywhere else, so the guard refuses the target there.
		@Test
		func catalogProcessingInstructionBeforeRootElementThrowsUnsupportedProcessingInstruction() {
			for body in ["<?oasis-xml-catalog catalog=\"x\"?><r/>", "<?xml version=\"1.0\"?><?oasis-xml-catalog?><r/>"] {
				assertThrows(.unsupported(.processingInstruction), Data(body.utf8), body)
			}
			for body in ["<r><?oasis-xml-catalog catalog=\"x\"?></r>", "<?oasis-xml-catalogs catalog=\"x\"?><r/>", "<?oasis-xml-catalo catalog=\"x\"?><r/>", "<?oasis-xml-catalof catalog=\"x\"?><r/>"] {
				assertAccepts(Data(body.utf8), body)
			}
		}

		@Test
		func markupDeclarationsThrowUnsupportedDoctype() {
			for body in ["<!DOCTYPE r><r/>", "<r><!ELEMENT r ANY></r>", "<r><![INCLUDE[x]]></r>", "<r><!-x--></r>"] {
				assertThrows(.unsupported(.doctype), Data(body.utf8), body)
			}
		}

		// MARK: - Encodings

		@Test
		func supportedEncodingsPass() {
			let body = "<r>x</r>"
			var bodies: [(String, Data)] = [
				("UTF-8", Data(body.utf8)),
				("UTF-8 with BOM", Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)),
				("UTF-8 with BOM and declaration", Data([0xEF, 0xBB, 0xBF]) + Data((declaration("UTF-8") + body).utf8))
			]
			for name in ["utf-8", "UTF-8", "utf8", "us-ascii", "ASCII", "ANSI_X3.4-1968"] {
				bodies.append((name, Data((declaration(name) + body).utf8)))
			}
			for (name, data) in bodies {
				assertAccepts(data, name)
			}
		}

		/// Every encoding other than UTF-8 and US-ASCII is refused, whether libxml2 would detect it from the first bytes or read it from the declaration.
		@Test
		func unsupportedEncodingsThrowUnsupportedEncoding() {
			let body = "<r>x</r>"
			var bodies: [(String, Data)] = [
				("UTF-8 declaring UTF-16", Data((declaration("UTF-16") + body).utf8)),
				("UTF-16 LE with BOM", utf16Data(body, bigEndian: false, withByteOrderMark: true)),
				("UTF-16 BE with BOM", utf16Data(body, bigEndian: true, withByteOrderMark: true)),
				("UTF-16 LE without BOM", utf16Data(declaration("UTF-16") + body, bigEndian: false, withByteOrderMark: false)),
				("UTF-16 BE without BOM", utf16Data(declaration("UTF-16") + body, bigEndian: true, withByteOrderMark: false)),
				("lone UTF-16 BOM", Data([0xFE, 0xFF])),
				("UTF-32 LE with BOM", Data([0xFF, 0xFE, 0x00, 0x00]) + utf32(body, bigEndian: false)),
				("UTF-32 BE with BOM", Data([0x00, 0x00, 0xFE, 0xFF]) + utf32(body, bigEndian: true)),
				("UCS-4 BE", utf32(body, bigEndian: true)),
				("UCS-4 LE", utf32(body, bigEndian: false)),
				("UCS-4 2143", Data([0x00, 0x00, 0x3C, 0x00, 0x00, 0x00, 0x72, 0x00])),
				("UCS-4 3412", Data([0x00, 0x3C, 0x00, 0x00, 0x00, 0x72, 0x00, 0x00])),
				("EBCDIC", Data([0x4C, 0x6F, 0xA7, 0x94, 0x93])),
				("UTF-8 BOM declaring Shift_JIS", Data([0xEF, 0xBB, 0xBF]) + Data((declaration("Shift_JIS") + body).utf8)),
				("single-quoted Shift_JIS", Data(("<?xml version='1.0' encoding='Shift_JIS'?>" + body).utf8)),
				("spaced Shift_JIS", Data(("<?xml version=\"1.0\" encoding = \"Shift_JIS\"?>" + body).utf8)),
				("declaration of Shift_JIS ending at its quote", Data("<?xml version=\"1.0\" encoding=\"Shift_JIS\"".utf8))
			]
			for name in ["Shift_JIS", "x-unknown", "ISO-8859-1", "ISO_8859-1", "L1", "windows-1252", "ISO-8859-15", "TIS-620", "latin-9"] {
				bodies.append((name, Data((declaration(name) + body).utf8)))
			}
			for (name, data) in bodies {
				assertThrows(.unsupported(.encoding), data, name)
			}
		}

		@Test
		func encodingOutsideXMLDeclarationIsIgnored() {
			for body in ["<?xml-stylesheet encoding=\"Shift_JIS\"?><r/>", "<r/><?xml version=\"1.0\" encoding=\"Shift_JIS\"?>"] {
				assertAccepts(Data(body.utf8), body)
			}
		}

		/// A body that ends inside an encoding value is left to libxml2, which reports the truncation.
		@Test
		func declarationEndingInsideEncodingValuePasses() {
			assertAccepts(Data("<?xml version=\"1.0\" encoding=\"Shift_JIS".utf8))
		}

		@Test
		func shortBodiesPass() {
			for body in [Data(), Data([0xEF, 0xBB, 0xBF]), Data([0x3C])] {
				assertAccepts(body)
			}
		}

		/// libxml2 detects no UTF-32 body that starts with whitespace, reads it as UTF-8 and rejects it on its NUL bytes.
		@Test
		func undetectedUTF32IsLeftToXMLParser() {
			let body = utf32(" <r/>", bigEndian: false)
			assertAccepts(body)
			#expect(!XMLParser(data: body).parse())
		}

		// MARK: - Files

		@Test
		func validatesFiles() throws {
			let overCap = Data(("<a><!--" + String(repeating: "c", count: WebDAVXMLLimits.maxDelimitedLength + 1) + "--></a>").utf8)
			let listingURL = try makeLocalFile(in: tmpDirURL, data: fixture("item-list"))
			let overCapURL = try makeLocalFile(in: tmpDirURL, data: overCap)
			let multibyteURL = try makeLocalFile(in: tmpDirURL, data: Data("<r>äöü😀</r>".utf8))
			let emptyURL = try makeLocalFile(in: tmpDirURL, data: Data())
			for chunkSize in WebDAVXMLGuardTests.fileChunkSizes {
				try WebDAVXMLGuard.validate(fileAt: listingURL, chunkSize: chunkSize)
				#expect(throws: WebDAVXMLGuardError.limitExceeded(.comment)) { try WebDAVXMLGuard.validate(fileAt: overCapURL, chunkSize: chunkSize) }
				try WebDAVXMLGuard.validate(fileAt: multibyteURL, chunkSize: chunkSize)
				try WebDAVXMLGuard.validate(fileAt: emptyURL, chunkSize: chunkSize)
			}
		}

		@Test
		func validatingFileInCancelledTaskThrowsCancellationError() async throws {
			let fileURL = try makeLocalFile(in: tmpDirURL, data: Data("<r/>".utf8))
			let task = cancelledTask { try WebDAVXMLGuard.validate(fileAt: fileURL) }
			await #expect(throws: CancellationError.self) { try await task.value }
		}

		/// A caller validates a body that answers a completed remote change, so a cancelled task must not stop it.
		@Test
		func validatingDataInCancelledTaskValidates() async throws {
			let task = cancelledTask { try WebDAVXMLGuard.validate(Data("<!DOCTYPE r><r/>".utf8)) }
			await #expect(throws: WebDAVXMLGuardError.unsupported(.doctype)) { try await task.value }
		}

		// MARK: - Helpers

		private func scan(_ body: Data, chunkSize: Int) throws {
			var markupGuard = WebDAVXMLGuard()
			var index = body.startIndex
			while index < body.endIndex {
				let end = min(index + chunkSize, body.endIndex)
				try markupGuard.feed(body[index ..< end])
				index = end
			}
			try markupGuard.finish()
		}

		/// Scans the body in every chunk size of `chunkSizes`, each of which must reach the same verdict.
		private func verdict(of body: Data, sourceLocation: SourceLocation) -> WebDAVXMLGuardError? {
			var verdicts = [WebDAVXMLGuardError?]()
			for chunkSize in WebDAVXMLGuardTests.chunkSizes {
				do {
					try scan(body, chunkSize: chunkSize)
					verdicts.append(nil)
				} catch let error as WebDAVXMLGuardError {
					verdicts.append(error)
				} catch {
					Issue.record(error, sourceLocation: sourceLocation)
				}
			}
			#expect(verdicts.allSatisfy { $0 == verdicts.first }, "\(verdicts)", sourceLocation: sourceLocation)
			return verdicts.first ?? nil
		}

		private func assertAccepts(_ body: Data, _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(verdict(of: body, sourceLocation: sourceLocation) == nil, Comment(rawValue: comment), sourceLocation: sourceLocation)
		}

		private func assertThrows(_ expected: WebDAVXMLGuardError, _ body: Data, _ comment: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
			#expect(verdict(of: body, sourceLocation: sourceLocation) == expected, Comment(rawValue: comment), sourceLocation: sourceLocation)
		}

		private func assertCapPair(_ construct: WebDAVXMLConstruct, _ atCap: String, _ overCap: String, sourceLocation: SourceLocation = #_sourceLocation) {
			assertCapPair(construct, Data(atCap.utf8), Data(overCap.utf8), sourceLocation: sourceLocation)
		}

		private func assertCapPair(_ construct: WebDAVXMLConstruct, _ atCap: Data, _ overCap: Data, sourceLocation: SourceLocation = #_sourceLocation) {
			assertAccepts(atCap, "at cap", sourceLocation: sourceLocation)
			assertThrows(.limitExceeded(construct), overCap, "over cap", sourceLocation: sourceLocation)
		}

		private func declaration(_ encodingName: String) -> String {
			return "<?xml version=\"1.0\" encoding=\"\(encodingName)\"?>"
		}

		private func utf32(_ string: String, bigEndian: Bool) -> Data {
			return Data(string.unicodeScalars.flatMap { scalar in
				let bytes = (0 ..< 4).map { UInt8((scalar.value >> (8 * $0)) & 0xFF) }
				return bigEndian ? Array(bytes.reversed()) : bytes
			})
		}

		private func fixture(_ name: String) throws -> Data {
			return try Data(contentsOf: #require(Bundle.module.url(forResource: name, withExtension: "xml")))
		}
	}
}
