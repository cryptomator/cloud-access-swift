//
//  CloudPathTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 24.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
@testable import CryptomatorCloudAccessCore

class CloudPathTests: XCTestCase {
	func testURLInitWithCloudPathRelativeToBase() throws {
		XCTAssertEqual("/foo/bar", try URL(cloudPath: CloudPath("/bar/"), relativeTo: XCTUnwrap(URL(string: "/foo/")))?.absoluteString)
		XCTAssertEqual("/foo/bar", try URL(cloudPath: CloudPath("/bar"), relativeTo: XCTUnwrap(URL(string: "/foo/")))?.absoluteString)
		XCTAssertEqual("/foo/bar", try URL(cloudPath: CloudPath("bar/"), relativeTo: XCTUnwrap(URL(string: "/foo/")))?.absoluteString)
		XCTAssertEqual("/foo/bar", try URL(cloudPath: CloudPath("bar"), relativeTo: XCTUnwrap(URL(string: "/foo/")))?.absoluteString)

		XCTAssertEqual("/bar", try URL(cloudPath: CloudPath("/bar/"), relativeTo: XCTUnwrap(URL(string: "/foo")))?.absoluteString)
		XCTAssertEqual("/bar", try URL(cloudPath: CloudPath("/bar"), relativeTo: XCTUnwrap(URL(string: "/foo")))?.absoluteString)
		XCTAssertEqual("/bar", try URL(cloudPath: CloudPath("bar/"), relativeTo: XCTUnwrap(URL(string: "/foo")))?.absoluteString)
		XCTAssertEqual("/bar", try URL(cloudPath: CloudPath("bar"), relativeTo: XCTUnwrap(URL(string: "/foo")))?.absoluteString)

		XCTAssertEqual("foo/bar", try URL(cloudPath: CloudPath("/bar/"), relativeTo: XCTUnwrap(URL(string: "foo/")))?.absoluteString)
		XCTAssertEqual("foo/bar", try URL(cloudPath: CloudPath("/bar"), relativeTo: XCTUnwrap(URL(string: "foo/")))?.absoluteString)
		XCTAssertEqual("foo/bar", try URL(cloudPath: CloudPath("bar/"), relativeTo: XCTUnwrap(URL(string: "foo/")))?.absoluteString)
		XCTAssertEqual("foo/bar", try URL(cloudPath: CloudPath("bar"), relativeTo: XCTUnwrap(URL(string: "foo/")))?.absoluteString)

		XCTAssertEqual("bar", try URL(cloudPath: CloudPath("/bar/"), relativeTo: XCTUnwrap(URL(string: "foo")))?.absoluteString)
		XCTAssertEqual("bar", try URL(cloudPath: CloudPath("/bar"), relativeTo: XCTUnwrap(URL(string: "foo")))?.absoluteString)
		XCTAssertEqual("bar", try URL(cloudPath: CloudPath("bar/"), relativeTo: XCTUnwrap(URL(string: "foo")))?.absoluteString)
		XCTAssertEqual("bar", try URL(cloudPath: CloudPath("bar"), relativeTo: XCTUnwrap(URL(string: "foo")))?.absoluteString)

		XCTAssertEqual("/foo/", try URL(cloudPath: CloudPath("/"), relativeTo: XCTUnwrap(URL(string: "/foo/")))?.absoluteString)
		XCTAssertEqual("/", try URL(cloudPath: CloudPath("/"), relativeTo: XCTUnwrap(URL(string: "/foo")))?.absoluteString)
		XCTAssertEqual("foo/", try URL(cloudPath: CloudPath("/"), relativeTo: XCTUnwrap(URL(string: "foo/")))?.absoluteString)
		XCTAssertEqual("", try URL(cloudPath: CloudPath("/"), relativeTo: XCTUnwrap(URL(string: "foo")))?.absoluteString)

		XCTAssertEqual("/foo", try URL(cloudPath: CloudPath("/foo/"), relativeTo: XCTUnwrap(URL(string: "/")))?.absoluteString)
		XCTAssertEqual("/foo", try URL(cloudPath: CloudPath("/foo"), relativeTo: XCTUnwrap(URL(string: "/")))?.absoluteString)
		XCTAssertEqual("/foo", try URL(cloudPath: CloudPath("foo/"), relativeTo: XCTUnwrap(URL(string: "/")))?.absoluteString)
		XCTAssertEqual("/foo", try URL(cloudPath: CloudPath("foo"), relativeTo: XCTUnwrap(URL(string: "/")))?.absoluteString)
	}

	func testTrimmingLeadingCharacters() {
		XCTAssertEqual("foo", "///foo".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
		XCTAssertEqual("foo///bar", "/foo///bar".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
		XCTAssertEqual("foo///bar", "foo///bar".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
	}

	func testStandardizedPath() {
		XCTAssertEqual("/../../foo/baz", "/../../foo/bar/.///../baz".standardizedPath())
	}

	func testIsSinglePathComponent() {
		XCTAssertFalse("a/b".isSinglePathComponent)
		XCTAssertFalse("".isSinglePathComponent)
		XCTAssertFalse(".".isSinglePathComponent)
		XCTAssertFalse("..".isSinglePathComponent)
		XCTAssertFalse("/x".isSinglePathComponent)
		XCTAssertFalse("x/".isSinglePathComponent)
		XCTAssertFalse("a/\u{301}b".isSinglePathComponent)

		XCTAssertTrue("ok".isSinglePathComponent)
		XCTAssertTrue(".hidden".isSinglePathComponent)
		XCTAssertTrue(#"a\b"#.isSinglePathComponent)
		XCTAssertTrue("..a".isSinglePathComponent)
		XCTAssertTrue("a b".isSinglePathComponent)
		XCTAssertTrue("\u{301}a".isSinglePathComponent)
		XCTAssertTrue("Gelöschte Dateien 🗑".isSinglePathComponent)
	}

	/// A slash and a combining mark that follows it are one `Character`, but the slash still separates.
	func testSeparatorBeforeCombiningMark() {
		let name = "\u{301}report.txt"
		let cloudPath = CloudPath("/foo").appendingPathComponent(name)
		XCTAssertEqual("/foo/\u{301}report.txt", cloudPath.path)
		XCTAssertEqual(["/", "foo", name], cloudPath.pathComponents)
		XCTAssertEqual(name, cloudPath.lastPathComponent)
		XCTAssertEqual("/foo", cloudPath.deletingLastPathComponent().path)
		XCTAssertEqual("/foo/\u{301}report", cloudPath.deletingPathExtension().path)
		XCTAssertEqual("/a.b/\u{301}c", CloudPath("/a.b/\u{301}c").deletingPathExtension().path)
		XCTAssertEqual("/foo/\u{301}report.txt.bak", cloudPath.appendingPathExtension("bak").path)
		XCTAssertEqual("/foo/\u{301}report.txt", CloudPath("/foo//\u{301}report.txt").path)
		XCTAssertEqual("/foo", CloudPath("/foo").appendingPathExtension("a/\u{301}b").path)

		let rootChild = CloudPath("/").appendingPathComponent(name)
		XCTAssertTrue(rootChild.isAbsolute)
		XCTAssertEqual(["/", name], rootChild.pathComponents)
		XCTAssertEqual("/", rootChild.deletingLastPathComponent().path)
	}

	func testPathComponents() {
		XCTAssertEqual(["/", "foo", "bar"], CloudPath("/foo/bar/").pathComponents)
		XCTAssertEqual(["/", "foo", "bar"], CloudPath("/foo/bar").pathComponents)
		XCTAssertEqual(["/", "foo"], CloudPath("/foo/").pathComponents)
		XCTAssertEqual(["/", "foo"], CloudPath("/foo").pathComponents)
		XCTAssertEqual(["foo"], CloudPath("foo/").pathComponents)
		XCTAssertEqual(["foo"], CloudPath("foo").pathComponents)

		XCTAssertEqual(["/", "foo"], CloudPath("///foo///").pathComponents)
		XCTAssertEqual(["foo"], CloudPath("foo///").pathComponents)
		XCTAssertEqual(["/", "foo"], CloudPath("///foo").pathComponents)
		XCTAssertEqual(["foo", "bar"], CloudPath("foo///bar").pathComponents)

		XCTAssertEqual(["/", ".."], CloudPath("/../").pathComponents)
		XCTAssertEqual(["/", ".."], CloudPath("/..").pathComponents)
		XCTAssertEqual([".."], CloudPath("../").pathComponents)
		XCTAssertEqual([".."], CloudPath("..").pathComponents)
		XCTAssertEqual(["/"], CloudPath("/./").pathComponents)
		XCTAssertEqual(["/"], CloudPath("/.").pathComponents)
		XCTAssertEqual(["."], CloudPath("./").pathComponents)
		XCTAssertEqual(["."], CloudPath(".").pathComponents)

		XCTAssertEqual(["/"], CloudPath("/").pathComponents)
		XCTAssertEqual(["."], CloudPath("").pathComponents)
	}

	func testLastPathComponent() {
		XCTAssertEqual("bar", CloudPath("/foo/bar/").lastPathComponent)
		XCTAssertEqual("bar", CloudPath("/foo/bar").lastPathComponent)
		XCTAssertEqual("foo", CloudPath("/foo/").lastPathComponent)
		XCTAssertEqual("foo", CloudPath("/foo").lastPathComponent)
		XCTAssertEqual("foo", CloudPath("foo/").lastPathComponent)
		XCTAssertEqual("foo", CloudPath("foo").lastPathComponent)

		XCTAssertEqual("foo", CloudPath("///foo///").lastPathComponent)
		XCTAssertEqual("foo", CloudPath("foo///").lastPathComponent)
		XCTAssertEqual("foo", CloudPath("///foo").lastPathComponent)
		XCTAssertEqual("bar", CloudPath("foo///bar").lastPathComponent)

		XCTAssertEqual("..", CloudPath("/../").lastPathComponent)
		XCTAssertEqual("..", CloudPath("/..").lastPathComponent)
		XCTAssertEqual("..", CloudPath("../").lastPathComponent)
		XCTAssertEqual("..", CloudPath("..").lastPathComponent)
		XCTAssertEqual("/", CloudPath("/./").lastPathComponent)
		XCTAssertEqual("/", CloudPath("/.").lastPathComponent)
		XCTAssertEqual(".", CloudPath("./").lastPathComponent)
		XCTAssertEqual(".", CloudPath(".").lastPathComponent)

		XCTAssertEqual("/", CloudPath("/").lastPathComponent)
		XCTAssertEqual(".", CloudPath("").lastPathComponent)
	}

	func testPathExtension() {
		XCTAssertEqual("qux", CloudPath("/foo.bar/baz.qux").pathExtension)
		XCTAssertEqual("", CloudPath("/foo.bar/baz").pathExtension)
		XCTAssertEqual("baz", CloudPath("/foo.bar.baz").pathExtension)
		XCTAssertEqual("", CloudPath("/foo.bar baz").pathExtension)
		XCTAssertEqual("", CloudPath("/foo.bar.").pathExtension)
		XCTAssertEqual("", CloudPath("/foo.bar. ").pathExtension)
		XCTAssertEqual("bar", CloudPath("/foo..bar").pathExtension)
		XCTAssertEqual("bar", CloudPath("/foo.bar").pathExtension)
		XCTAssertEqual("", CloudPath("/foo. bar").pathExtension)
		XCTAssertEqual("", CloudPath("/foo").pathExtension)
		XCTAssertEqual("", CloudPath("..").pathExtension)
		XCTAssertEqual("", CloudPath(".").pathExtension)
		XCTAssertEqual("", CloudPath("/").pathExtension)
		XCTAssertEqual("", CloudPath("").pathExtension)
	}

	func testAppendingPathComponent() {
		XCTAssertEqual("/foo/bar", CloudPath("/foo/").appendingPathComponent("/bar/").path)
		XCTAssertEqual("/foo/bar", CloudPath("/foo/").appendingPathComponent("/bar").path)
		XCTAssertEqual("/foo/bar", CloudPath("/foo/").appendingPathComponent("bar/").path)
		XCTAssertEqual("/foo/bar", CloudPath("/foo/").appendingPathComponent("bar").path)

		XCTAssertEqual("/foo/bar", CloudPath("/foo").appendingPathComponent("/bar/").path)
		XCTAssertEqual("/foo/bar", CloudPath("/foo").appendingPathComponent("/bar").path)
		XCTAssertEqual("/foo/bar", CloudPath("/foo").appendingPathComponent("bar/").path)
		XCTAssertEqual("/foo/bar", CloudPath("/foo").appendingPathComponent("bar").path)

		XCTAssertEqual("foo/bar", CloudPath("foo/").appendingPathComponent("/bar/").path)
		XCTAssertEqual("foo/bar", CloudPath("foo/").appendingPathComponent("/bar").path)
		XCTAssertEqual("foo/bar", CloudPath("foo/").appendingPathComponent("bar/").path)
		XCTAssertEqual("foo/bar", CloudPath("foo/").appendingPathComponent("bar").path)

		XCTAssertEqual("foo/bar", CloudPath("foo").appendingPathComponent("/bar/").path)
		XCTAssertEqual("foo/bar", CloudPath("foo").appendingPathComponent("/bar").path)
		XCTAssertEqual("foo/bar", CloudPath("foo").appendingPathComponent("bar/").path)
		XCTAssertEqual("foo/bar", CloudPath("foo").appendingPathComponent("bar").path)

		XCTAssertEqual("/foo/bar", CloudPath("///foo///").appendingPathComponent("///bar///").path)
		XCTAssertEqual("/foo", CloudPath("/").appendingPathComponent("foo").path)
		XCTAssertEqual("foo", CloudPath("").appendingPathComponent("foo").path)
	}

	func testDeletingLastPathComponent() {
		XCTAssertEqual("/foo", CloudPath("/foo/bar/").deletingLastPathComponent().path)
		XCTAssertEqual("/foo", CloudPath("/foo/bar").deletingLastPathComponent().path)
		XCTAssertEqual("/", CloudPath("/foo/").deletingLastPathComponent().path)
		XCTAssertEqual("/", CloudPath("/foo").deletingLastPathComponent().path)
		XCTAssertEqual(".", CloudPath("foo/").deletingLastPathComponent().path)
		XCTAssertEqual(".", CloudPath("foo").deletingLastPathComponent().path)

		XCTAssertEqual("/", CloudPath("///foo///").deletingLastPathComponent().path)
		XCTAssertEqual(".", CloudPath("foo///").deletingLastPathComponent().path)
		XCTAssertEqual("/", CloudPath("///foo").deletingLastPathComponent().path)
		XCTAssertEqual("foo", CloudPath("foo///bar").deletingLastPathComponent().path)

		XCTAssertEqual("/../..", CloudPath("/../").deletingLastPathComponent().path)
		XCTAssertEqual("/../..", CloudPath("/..").deletingLastPathComponent().path)
		XCTAssertEqual("../..", CloudPath("../").deletingLastPathComponent().path)
		XCTAssertEqual("../..", CloudPath("..").deletingLastPathComponent().path)
		XCTAssertEqual("/..", CloudPath("/./").deletingLastPathComponent().path)
		XCTAssertEqual("/..", CloudPath("/.").deletingLastPathComponent().path)
		XCTAssertEqual("..", CloudPath("./").deletingLastPathComponent().path)
		XCTAssertEqual("..", CloudPath(".").deletingLastPathComponent().path)

		XCTAssertEqual("/..", CloudPath("/").deletingLastPathComponent().path)
		XCTAssertEqual("..", CloudPath("").deletingLastPathComponent().path)
	}

	func testAppendingPathExtension() {
		XCTAssertEqual("/foo.bar.baz", CloudPath("/foo").appendingPathExtension("bar.baz").path)
		XCTAssertEqual("/foo", CloudPath("/foo").appendingPathExtension("bar baz").path)
		XCTAssertEqual("/foo", CloudPath("/foo").appendingPathExtension("bar.").path)
		XCTAssertEqual("/foo", CloudPath("/foo").appendingPathExtension("bar. ").path)
		XCTAssertEqual("/foo..bar", CloudPath("/foo").appendingPathExtension(".bar").path)
		XCTAssertEqual("/foo.bar", CloudPath("/foo").appendingPathExtension("bar").path)
		XCTAssertEqual("/foo", CloudPath("/foo").appendingPathExtension(" bar").path)
		XCTAssertEqual("/foo", CloudPath("/foo").appendingPathExtension("/bar").path)
		XCTAssertEqual("/foo", CloudPath("/foo").appendingPathExtension("").path)
		XCTAssertEqual("/.foo", CloudPath("/").appendingPathExtension("foo").path)
		XCTAssertEqual("...foo", CloudPath("..").appendingPathExtension("foo").path)
		XCTAssertEqual("..foo", CloudPath(".").appendingPathExtension("foo").path)
		XCTAssertEqual("..foo", CloudPath("").appendingPathExtension("foo").path)
	}

	func testDeletingPathExtension() {
		XCTAssertEqual("/foo.bar", CloudPath("/foo.bar.baz").deletingPathExtension().path)
		XCTAssertEqual("/foo", CloudPath("/foo.bar baz").deletingPathExtension().path)
		XCTAssertEqual("/foo.bar.", CloudPath("/foo.bar.").deletingPathExtension().path)
		XCTAssertEqual("/foo.bar", CloudPath("/foo.bar. ").deletingPathExtension().path)
		XCTAssertEqual("/foo.", CloudPath("/foo..bar").deletingPathExtension().path)
		XCTAssertEqual("/foo", CloudPath("/foo.bar").deletingPathExtension().path)
		XCTAssertEqual("/foo", CloudPath("/foo. bar").deletingPathExtension().path)
		XCTAssertEqual("/foo", CloudPath("/foo").deletingPathExtension().path)
		XCTAssertEqual("..", CloudPath("..").deletingPathExtension().path)
		XCTAssertEqual(".", CloudPath(".").deletingPathExtension().path)
		XCTAssertEqual("/", CloudPath("/").deletingPathExtension().path)
		XCTAssertEqual(".", CloudPath("").deletingPathExtension().path)
	}
}
