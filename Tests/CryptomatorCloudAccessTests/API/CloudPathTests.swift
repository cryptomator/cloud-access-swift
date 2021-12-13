//
//  CloudPathTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 24.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class CloudPathTests: XCTestCase {
	func testURLInitWithCloudPathRelativeToBase() {
		XCTAssertEqual("///foo/bar", URL(cloudPath: CloudPath("/bar/"), relativeTo: URL(string: "/foo/")!)!.absoluteString)
		XCTAssertEqual("///foo/bar", URL(cloudPath: CloudPath("/bar"), relativeTo: URL(string: "/foo/")!)!.absoluteString)
		XCTAssertEqual("///foo/bar", URL(cloudPath: CloudPath("bar/"), relativeTo: URL(string: "/foo/")!)!.absoluteString)
		XCTAssertEqual("///foo/bar", URL(cloudPath: CloudPath("bar"), relativeTo: URL(string: "/foo/")!)!.absoluteString)

		XCTAssertEqual("///bar", URL(cloudPath: CloudPath("/bar/"), relativeTo: URL(string: "/foo")!)!.absoluteString)
		XCTAssertEqual("///bar", URL(cloudPath: CloudPath("/bar"), relativeTo: URL(string: "/foo")!)!.absoluteString)
		XCTAssertEqual("///bar", URL(cloudPath: CloudPath("bar/"), relativeTo: URL(string: "/foo")!)!.absoluteString)
		XCTAssertEqual("///bar", URL(cloudPath: CloudPath("bar"), relativeTo: URL(string: "/foo")!)!.absoluteString)

		XCTAssertEqual("//foo/bar", URL(cloudPath: CloudPath("/bar/"), relativeTo: URL(string: "foo/")!)!.absoluteString)
		XCTAssertEqual("//foo/bar", URL(cloudPath: CloudPath("/bar"), relativeTo: URL(string: "foo/")!)!.absoluteString)
		XCTAssertEqual("//foo/bar", URL(cloudPath: CloudPath("bar/"), relativeTo: URL(string: "foo/")!)!.absoluteString)
		XCTAssertEqual("//foo/bar", URL(cloudPath: CloudPath("bar"), relativeTo: URL(string: "foo/")!)!.absoluteString)

		XCTAssertEqual("//bar", URL(cloudPath: CloudPath("/bar/"), relativeTo: URL(string: "foo")!)!.absoluteString)
		XCTAssertEqual("//bar", URL(cloudPath: CloudPath("/bar"), relativeTo: URL(string: "foo")!)!.absoluteString)
		XCTAssertEqual("//bar", URL(cloudPath: CloudPath("bar/"), relativeTo: URL(string: "foo")!)!.absoluteString)
		XCTAssertEqual("//bar", URL(cloudPath: CloudPath("bar"), relativeTo: URL(string: "foo")!)!.absoluteString)

		XCTAssertEqual("///foo/", URL(cloudPath: CloudPath("/"), relativeTo: URL(string: "/foo/")!)!.absoluteString)
		XCTAssertEqual("///", URL(cloudPath: CloudPath("/"), relativeTo: URL(string: "/foo")!)!.absoluteString)
		XCTAssertEqual("//foo/", URL(cloudPath: CloudPath("/"), relativeTo: URL(string: "foo/")!)!.absoluteString)
		XCTAssertEqual("//.", URL(cloudPath: CloudPath("/"), relativeTo: URL(string: "foo")!)!.absoluteString)

		XCTAssertEqual("///foo", URL(cloudPath: CloudPath("/foo/"), relativeTo: URL(string: "/")!)!.absoluteString)
		XCTAssertEqual("///foo", URL(cloudPath: CloudPath("/foo"), relativeTo: URL(string: "/")!)!.absoluteString)
		XCTAssertEqual("///foo", URL(cloudPath: CloudPath("foo/"), relativeTo: URL(string: "/")!)!.absoluteString)
		XCTAssertEqual("///foo", URL(cloudPath: CloudPath("foo"), relativeTo: URL(string: "/")!)!.absoluteString)
	}

	func testTrimmingLeadingCharacters() {
		XCTAssertEqual("foo", "///foo".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
		XCTAssertEqual("foo///bar", "/foo///bar".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
		XCTAssertEqual("foo///bar", "foo///bar".trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/")))
	}

	func testStandardizedPath() {
		XCTAssertEqual("/../../foo/baz", "/../../foo/bar/.///../baz".standardizedPath())
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
