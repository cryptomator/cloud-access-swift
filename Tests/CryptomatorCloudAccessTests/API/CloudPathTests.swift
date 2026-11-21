//
//  CloudPathTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 24.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	struct CloudPathTests {
		@Test
		func urlInitWithCloudPathRelativeToBase() throws {
			#expect(try URL(cloudPath: CloudPath("/bar/"), relativeTo: #require(URL(string: "/foo/")))?.absoluteString == "/foo/bar")
			#expect(try URL(cloudPath: CloudPath("/bar"), relativeTo: #require(URL(string: "/foo/")))?.absoluteString == "/foo/bar")
			#expect(try URL(cloudPath: CloudPath("bar/"), relativeTo: #require(URL(string: "/foo/")))?.absoluteString == "/foo/bar")
			#expect(try URL(cloudPath: CloudPath("bar"), relativeTo: #require(URL(string: "/foo/")))?.absoluteString == "/foo/bar")

			#expect(try URL(cloudPath: CloudPath("/bar/"), relativeTo: #require(URL(string: "/foo")))?.absoluteString == "/bar")
			#expect(try URL(cloudPath: CloudPath("/bar"), relativeTo: #require(URL(string: "/foo")))?.absoluteString == "/bar")
			#expect(try URL(cloudPath: CloudPath("bar/"), relativeTo: #require(URL(string: "/foo")))?.absoluteString == "/bar")
			#expect(try URL(cloudPath: CloudPath("bar"), relativeTo: #require(URL(string: "/foo")))?.absoluteString == "/bar")

			#expect(try URL(cloudPath: CloudPath("/bar/"), relativeTo: #require(URL(string: "foo/")))?.absoluteString == "foo/bar")
			#expect(try URL(cloudPath: CloudPath("/bar"), relativeTo: #require(URL(string: "foo/")))?.absoluteString == "foo/bar")
			#expect(try URL(cloudPath: CloudPath("bar/"), relativeTo: #require(URL(string: "foo/")))?.absoluteString == "foo/bar")
			#expect(try URL(cloudPath: CloudPath("bar"), relativeTo: #require(URL(string: "foo/")))?.absoluteString == "foo/bar")

			#expect(try URL(cloudPath: CloudPath("/bar/"), relativeTo: #require(URL(string: "foo")))?.absoluteString == "bar")
			#expect(try URL(cloudPath: CloudPath("/bar"), relativeTo: #require(URL(string: "foo")))?.absoluteString == "bar")
			#expect(try URL(cloudPath: CloudPath("bar/"), relativeTo: #require(URL(string: "foo")))?.absoluteString == "bar")
			#expect(try URL(cloudPath: CloudPath("bar"), relativeTo: #require(URL(string: "foo")))?.absoluteString == "bar")

			#expect(try URL(cloudPath: CloudPath("/"), relativeTo: #require(URL(string: "/foo/")))?.absoluteString == "/foo/")
			#expect(try URL(cloudPath: CloudPath("/"), relativeTo: #require(URL(string: "/foo")))?.absoluteString == "/")
			#expect(try URL(cloudPath: CloudPath("/"), relativeTo: #require(URL(string: "foo/")))?.absoluteString == "foo/")
			#expect(try URL(cloudPath: CloudPath("/"), relativeTo: #require(URL(string: "foo")))?.absoluteString == "")

			#expect(try URL(cloudPath: CloudPath("/foo/"), relativeTo: #require(URL(string: "/")))?.absoluteString == "/foo")
			#expect(try URL(cloudPath: CloudPath("/foo"), relativeTo: #require(URL(string: "/")))?.absoluteString == "/foo")
			#expect(try URL(cloudPath: CloudPath("foo/"), relativeTo: #require(URL(string: "/")))?.absoluteString == "/foo")
			#expect(try URL(cloudPath: CloudPath("foo"), relativeTo: #require(URL(string: "/")))?.absoluteString == "/foo")
		}

		@Test
		func appendingCloudPath() throws {
			let basePath = "/\(UUID().uuidString)/foo"
			for base in [URL(filePath: basePath, directoryHint: .notDirectory), URL(filePath: basePath + "/", directoryHint: .isDirectory)] {
				#expect(base.appending(cloudPath: CloudPath("/")) == base)
				#expect(base.appending(cloudPath: CloudPath("/bar")).path == basePath + "/bar")
				#expect(base.appending(cloudPath: CloudPath("bar")).path == basePath + "/bar")
				#expect(base.appending(cloudPath: CloudPath("/bar/")).path == basePath + "/bar")
				#expect(base.appending(cloudPath: CloudPath("/bar/baz")).path == basePath + "/bar/baz")
				#expect(base.appending(cloudPath: CloudPath("")).path == basePath + "/.")
				#expect(base.appending(cloudPath: CloudPath("../y")).path == basePath + "/../y")
				for name in ["a b", "a%2Fb", "q?x", "h#x", "e\u{301}"] {
					#expect(Array(base.appending(cloudPath: CloudPath("/").appendingPathComponent(name)).path.utf8) == Array((basePath + "/" + name).utf8), "\(name)")
				}

				let decodedCloudPath = try JSONDecoder().decode(CloudPath.self, from: Data(#"{"path":"/bar/"}"#.utf8))
				#expect(decodedCloudPath.path == "/bar/")
				#expect(base.appending(cloudPath: decodedCloudPath).hasDirectoryPath)
				#expect(base.appending(cloudPath: decodedCloudPath).path == basePath + "/bar")
			}
			#expect(URL(filePath: "/", directoryHint: .isDirectory).appending(cloudPath: CloudPath("/bar")).path == "/bar")
		}

		@Test
		func testTrimmingLeadingCharacters() {
			#expect("foo" == "///foo".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
			#expect("foo///bar" == "/foo///bar".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
			#expect("foo///bar" == "foo///bar".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
		}

		@Test
		func testStandardizedPath() {
			#expect("/../../foo/baz" == "/../../foo/bar/.///../baz".standardizedPath())
		}

		@Test
		func testIsSinglePathComponent() {
			#expect(!"a/b".isSinglePathComponent)
			#expect(!"".isSinglePathComponent)
			#expect(!".".isSinglePathComponent)
			#expect(!"..".isSinglePathComponent)
			#expect(!"/x".isSinglePathComponent)
			#expect(!"x/".isSinglePathComponent)
			#expect(!"a/\u{301}b".isSinglePathComponent)

			#expect("ok".isSinglePathComponent)
			#expect(".hidden".isSinglePathComponent)
			#expect(#"a\b"#.isSinglePathComponent)
			#expect("..a".isSinglePathComponent)
			#expect("a b".isSinglePathComponent)
			#expect("\u{301}a".isSinglePathComponent)
			#expect("Gelöschte Dateien 🗑".isSinglePathComponent)
		}

		/// A slash and a combining mark that follows it are one `Character`, but the slash still separates.
		@Test
		func separatorBeforeCombiningMark() {
			let name = "\u{301}report.txt"
			let cloudPath = CloudPath("/foo").appendingPathComponent(name)
			#expect(cloudPath.path == "/foo/\u{301}report.txt")
			#expect(["/", "foo", name] == cloudPath.pathComponents)
			#expect(name == cloudPath.lastPathComponent)
			#expect(cloudPath.deletingLastPathComponent().path == "/foo")
			#expect(cloudPath.deletingPathExtension().path == "/foo/\u{301}report")
			#expect(CloudPath("/a.b/\u{301}c").deletingPathExtension().path == "/a.b/\u{301}c")
			#expect(cloudPath.appendingPathExtension("bak").path == "/foo/\u{301}report.txt.bak")
			#expect(CloudPath("/foo//\u{301}report.txt").path == "/foo/\u{301}report.txt")
			#expect(CloudPath("/foo").appendingPathExtension("a/\u{301}b").path == "/foo")

			let rootChild = CloudPath("/").appendingPathComponent(name)
			#expect(rootChild.isAbsolute)
			#expect(["/", name] == rootChild.pathComponents)
			#expect(rootChild.deletingLastPathComponent().path == "/")
		}

		/// A dot or a space forms one `Character` with a combining mark after it or a prepended mark (e.g. U+0600) before it, but it still separates the extension or rules it out.
		@Test
		func extensionSeparatorInCombinedCharacter() {
			let cloudPath = CloudPath("/foo/report.\u{301}txt")
			#expect(cloudPath.pathExtension == "\u{301}txt")
			#expect(cloudPath.deletingPathExtension().path == "/foo/report")
			#expect(CloudPath("/foo").appendingPathExtension("bar\u{600}.").path == "/foo")
			#expect(CloudPath("/foo").appendingPathExtension("bar \u{301}").path == "/foo")
		}

		/// An ASCII prefix or suffix forms one `Character` with a combining mark after it or a prepended mark before it, but it is still removed, and the rest keeps its bytes.
		@Test
		func removingASCIIAffixInCombinedCharacter() {
			#expect("0\u{301}abc".removingASCIIPrefix("0").map { Array($0.utf8) } == Array("\u{301}abc".utf8))
			#expect("x\u{600}.c9r".removingASCIISuffix(".c9r").map { Array($0.utf8) } == Array("x\u{600}".utf8))
			#expect(".c9r".removingASCIISuffix(".c9r") == "")
			#expect("abc".removingASCIIPrefix("0") == nil)
			#expect("abc".removingASCIISuffix(".c9r") == nil)
			#expect("".removingASCIIPrefix("0") == nil)
			#expect("".removingASCIISuffix(".c9r") == nil)
		}

		@Test
		func testPathComponents() {
			#expect(CloudPath("/foo/bar/").pathComponents == ["/", "foo", "bar"])
			#expect(CloudPath("/foo/bar").pathComponents == ["/", "foo", "bar"])
			#expect(CloudPath("/foo/").pathComponents == ["/", "foo"])
			#expect(CloudPath("/foo").pathComponents == ["/", "foo"])
			#expect(CloudPath("foo/").pathComponents == ["foo"])
			#expect(CloudPath("foo").pathComponents == ["foo"])

			#expect(CloudPath("///foo///").pathComponents == ["/", "foo"])
			#expect(CloudPath("foo///").pathComponents == ["foo"])
			#expect(CloudPath("///foo").pathComponents == ["/", "foo"])
			#expect(CloudPath("foo///bar").pathComponents == ["foo", "bar"])

			#expect(CloudPath("/../").pathComponents == ["/", ".."])
			#expect(CloudPath("/..").pathComponents == ["/", ".."])
			#expect(CloudPath("../").pathComponents == [".."])
			#expect(CloudPath("..").pathComponents == [".."])
			#expect(CloudPath("/./").pathComponents == ["/"])
			#expect(CloudPath("/.").pathComponents == ["/"])
			#expect(CloudPath("./").pathComponents == ["."])
			#expect(CloudPath(".").pathComponents == ["."])

			#expect(CloudPath("/").pathComponents == ["/"])
			#expect(CloudPath("").pathComponents == ["."])
		}

		@Test
		func testLastPathComponent() {
			#expect(CloudPath("/foo/bar/").lastPathComponent == "bar")
			#expect(CloudPath("/foo/bar").lastPathComponent == "bar")
			#expect(CloudPath("/foo/").lastPathComponent == "foo")
			#expect(CloudPath("/foo").lastPathComponent == "foo")
			#expect(CloudPath("foo/").lastPathComponent == "foo")
			#expect(CloudPath("foo").lastPathComponent == "foo")

			#expect(CloudPath("///foo///").lastPathComponent == "foo")
			#expect(CloudPath("foo///").lastPathComponent == "foo")
			#expect(CloudPath("///foo").lastPathComponent == "foo")
			#expect(CloudPath("foo///bar").lastPathComponent == "bar")

			#expect(CloudPath("/../").lastPathComponent == "..")
			#expect(CloudPath("/..").lastPathComponent == "..")
			#expect(CloudPath("../").lastPathComponent == "..")
			#expect(CloudPath("..").lastPathComponent == "..")
			#expect(CloudPath("/./").lastPathComponent == "/")
			#expect(CloudPath("/.").lastPathComponent == "/")
			#expect(CloudPath("./").lastPathComponent == ".")
			#expect(CloudPath(".").lastPathComponent == ".")

			#expect(CloudPath("/").lastPathComponent == "/")
			#expect(CloudPath("").lastPathComponent == ".")
		}

		@Test
		func testPathExtension() {
			#expect(CloudPath("/foo.bar/baz.qux").pathExtension == "qux")
			#expect(CloudPath("/foo.bar/baz").pathExtension == "")
			#expect(CloudPath("/foo.bar.baz").pathExtension == "baz")
			#expect(CloudPath("/foo.bar baz").pathExtension == "")
			#expect(CloudPath("/foo.bar.").pathExtension == "")
			#expect(CloudPath("/foo.bar. ").pathExtension == "")
			#expect(CloudPath("/foo..bar").pathExtension == "bar")
			#expect(CloudPath("/foo.bar").pathExtension == "bar")
			#expect(CloudPath("/foo. bar").pathExtension == "")
			#expect(CloudPath("/foo").pathExtension == "")
			#expect(CloudPath("..").pathExtension == "")
			#expect(CloudPath(".").pathExtension == "")
			#expect(CloudPath("/").pathExtension == "")
			#expect(CloudPath("").pathExtension == "")
		}

		@Test
		func testAppendingPathComponent() {
			#expect(CloudPath("/foo/").appendingPathComponent("/bar/").path == "/foo/bar")
			#expect(CloudPath("/foo/").appendingPathComponent("/bar").path == "/foo/bar")
			#expect(CloudPath("/foo/").appendingPathComponent("bar/").path == "/foo/bar")
			#expect(CloudPath("/foo/").appendingPathComponent("bar").path == "/foo/bar")

			#expect(CloudPath("/foo").appendingPathComponent("/bar/").path == "/foo/bar")
			#expect(CloudPath("/foo").appendingPathComponent("/bar").path == "/foo/bar")
			#expect(CloudPath("/foo").appendingPathComponent("bar/").path == "/foo/bar")
			#expect(CloudPath("/foo").appendingPathComponent("bar").path == "/foo/bar")

			#expect(CloudPath("foo/").appendingPathComponent("/bar/").path == "foo/bar")
			#expect(CloudPath("foo/").appendingPathComponent("/bar").path == "foo/bar")
			#expect(CloudPath("foo/").appendingPathComponent("bar/").path == "foo/bar")
			#expect(CloudPath("foo/").appendingPathComponent("bar").path == "foo/bar")

			#expect(CloudPath("foo").appendingPathComponent("/bar/").path == "foo/bar")
			#expect(CloudPath("foo").appendingPathComponent("/bar").path == "foo/bar")
			#expect(CloudPath("foo").appendingPathComponent("bar/").path == "foo/bar")
			#expect(CloudPath("foo").appendingPathComponent("bar").path == "foo/bar")

			#expect(CloudPath("///foo///").appendingPathComponent("///bar///").path == "/foo/bar")
			#expect(CloudPath("/").appendingPathComponent("foo").path == "/foo")
			#expect(CloudPath("").appendingPathComponent("foo").path == "foo")
		}

		@Test
		func testDeletingLastPathComponent() {
			#expect(CloudPath("/foo/bar/").deletingLastPathComponent().path == "/foo")
			#expect(CloudPath("/foo/bar").deletingLastPathComponent().path == "/foo")
			#expect(CloudPath("/foo/").deletingLastPathComponent().path == "/")
			#expect(CloudPath("/foo").deletingLastPathComponent().path == "/")
			#expect(CloudPath("foo/").deletingLastPathComponent().path == ".")
			#expect(CloudPath("foo").deletingLastPathComponent().path == ".")

			#expect(CloudPath("///foo///").deletingLastPathComponent().path == "/")
			#expect(CloudPath("foo///").deletingLastPathComponent().path == ".")
			#expect(CloudPath("///foo").deletingLastPathComponent().path == "/")
			#expect(CloudPath("foo///bar").deletingLastPathComponent().path == "foo")

			#expect(CloudPath("/../").deletingLastPathComponent().path == "/../..")
			#expect(CloudPath("/..").deletingLastPathComponent().path == "/../..")
			#expect(CloudPath("../").deletingLastPathComponent().path == "../..")
			#expect(CloudPath("..").deletingLastPathComponent().path == "../..")
			#expect(CloudPath("/./").deletingLastPathComponent().path == "/..")
			#expect(CloudPath("/.").deletingLastPathComponent().path == "/..")
			#expect(CloudPath("./").deletingLastPathComponent().path == "..")
			#expect(CloudPath(".").deletingLastPathComponent().path == "..")

			#expect(CloudPath("/").deletingLastPathComponent().path == "/..")
			#expect(CloudPath("").deletingLastPathComponent().path == "..")
		}

		@Test
		func testAppendingPathExtension() {
			#expect(CloudPath("/foo").appendingPathExtension("bar.baz").path == "/foo.bar.baz")
			#expect(CloudPath("/foo").appendingPathExtension("bar baz").path == "/foo")
			#expect(CloudPath("/foo").appendingPathExtension("bar.").path == "/foo")
			#expect(CloudPath("/foo").appendingPathExtension("bar. ").path == "/foo")
			#expect(CloudPath("/foo").appendingPathExtension(".bar").path == "/foo..bar")
			#expect(CloudPath("/foo").appendingPathExtension("bar").path == "/foo.bar")
			#expect(CloudPath("/foo").appendingPathExtension(" bar").path == "/foo")
			#expect(CloudPath("/foo").appendingPathExtension("/bar").path == "/foo")
			#expect(CloudPath("/foo").appendingPathExtension("").path == "/foo")
			#expect(CloudPath("/").appendingPathExtension("foo").path == "/.foo")
			#expect(CloudPath("..").appendingPathExtension("foo").path == "...foo")
			#expect(CloudPath(".").appendingPathExtension("foo").path == "..foo")
			#expect(CloudPath("").appendingPathExtension("foo").path == "..foo")
		}

		@Test
		func testDeletingPathExtension() {
			#expect(CloudPath("/foo.bar.baz").deletingPathExtension().path == "/foo.bar")
			#expect(CloudPath("/foo.bar baz").deletingPathExtension().path == "/foo")
			#expect(CloudPath("/foo.bar.").deletingPathExtension().path == "/foo.bar.")
			#expect(CloudPath("/foo.bar. ").deletingPathExtension().path == "/foo.bar")
			#expect(CloudPath("/foo..bar").deletingPathExtension().path == "/foo.")
			#expect(CloudPath("/foo.bar").deletingPathExtension().path == "/foo")
			#expect(CloudPath("/foo. bar").deletingPathExtension().path == "/foo")
			#expect(CloudPath("/foo").deletingPathExtension().path == "/foo")
			#expect(CloudPath("..").deletingPathExtension().path == "..")
			#expect(CloudPath(".").deletingPathExtension().path == ".")
			#expect(CloudPath("/").deletingPathExtension().path == "/")
			#expect(CloudPath("").deletingPathExtension().path == ".")
		}
	}
}
