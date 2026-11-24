//
//  CloudPath.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 21.08.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation

public extension URL {
	init?(cloudPath: CloudPath, relativeTo base: URL) {
		let trimmedPath = cloudPath.path.trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/"))
		if trimmedPath.isEmpty {
			self.init(string: ".", relativeTo: base)
		} else {
			guard let percentEncodedPath = trimmedPath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
				return nil
			}
			self.init(string: percentEncodedPath, relativeTo: base)
		}
	}

	/// Appends the cloud path without consulting the file system, so an existing folder's URL gets a trailing slash only if the cloud path has one. The root returns the URL unchanged.
	func appending(cloudPath: CloudPath) -> URL {
		let trimmedPath = cloudPath.path.trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/"))
		if trimmedPath.isEmpty {
			return self
		} else {
			return appending(path: trimmedPath)
		}
	}
}

extension String {
	func trimmingLeadingCharacters(in set: CharacterSet) -> String {
		var string = self
		while let range = string.rangeOfCharacter(from: set, options: [.anchored]) {
			string = String(string[range.upperBound...])
		}
		return string
	}

	func standardizedPath() -> String {
		return pathSegments().standardized().joined(separator: "/")
	}

	func pathSegments() -> [String] {
		return segments(separatedBy: "/")
	}

	/// Splits the string at every occurrence of the separator, keeping empty segments. It compares Unicode scalars, because a separator such as `/` or `.` forms one `Character` with a combining mark after it or a prepended mark (e.g. U+0600) before it, so a `Character`-based search misses it.
	func segments(separatedBy separator: Unicode.Scalar) -> [String] {
		return unicodeScalars.split(separator: separator, omittingEmptySubsequences: false).map { String(Substring($0)) }
	}

	/// Whether the string starts with the prefix's UTF-8 bytes. A `Character`-based search would miss a prefix whose end forms one `Character` with a combining mark after it. It would also match a canonically equivalent spelling, which a cloud can store as a different name.
	func hasUTF8Prefix(_ prefix: String) -> Bool {
		return utf8.starts(with: prefix.utf8)
	}

	/// Whether the string ends with the suffix's UTF-8 bytes. A `Character`-based search would miss a suffix whose start forms one `Character` with a prepended mark (e.g. U+0600) before it. It would also match a canonically equivalent spelling, which a cloud can store as a different name.
	func hasUTF8Suffix(_ suffix: String) -> Bool {
		return utf8.suffix(suffix.utf8.count).elementsEqual(suffix.utf8)
	}

	/// Returns the string without the prefix, or `nil` if it doesn't start with the prefix's UTF-8 bytes (see `hasUTF8Prefix(_:)`).
	func removingUTF8Prefix(_ prefix: String) -> String? {
		guard hasUTF8Prefix(prefix) else {
			return nil
		}
		return String(Substring(utf8.dropFirst(prefix.utf8.count)))
	}

	/// Returns the string without the suffix, or `nil` if it doesn't end with the suffix's UTF-8 bytes (see `hasUTF8Suffix(_:)`).
	func removingUTF8Suffix(_ suffix: String) -> String? {
		guard hasUTF8Suffix(suffix) else {
			return nil
		}
		return String(Substring(utf8.dropLast(suffix.utf8.count)))
	}

	/// Whether appending the string to a cloud path adds exactly one component equal to the string, rather than nesting it, dropping a slash or resolving to the folder or its parent.
	var isSinglePathComponent: Bool {
		return !isEmpty && !unicodeScalars.contains("/") && self != "." && self != ".."
	}
}

private extension [String] {
	func standardized() -> [String] {
		var standardized: [String] = []
		for element in self where !element.isEmpty && element != "." {
			if let lastElement = standardized.last, lastElement != "..", element == ".." {
				standardized.removeLast()
			} else {
				standardized.append(element)
			}
		}
		if count > 1, standardized.isEmpty, let isAbsolute = first?.isEmpty, isAbsolute {
			return ["", ""]
		} else if standardized.isEmpty {
			return ["."]
		} else if let isAbsolute = first?.isEmpty, isAbsolute {
			standardized.insert("", at: 0)
		}
		return standardized
	}
}

/**
 `CloudPath` is a type that contains the location of a resource on a remote server, the path of a local file on disk, or even an arbitrary piece of encoded data.

 This type mimics the behavior of `URL` but does not implement it and has a reduced set of methods. E.g., a `CloudPath` is not bound to a certain cloud provider or file system and the same path can be used for different providers.
 */
public struct CloudPath: Equatable, Codable, Sendable {
	public let path: String

	public var isAbsolute: Bool {
		return path.unicodeScalars.first == "/"
	}

	public var pathComponents: [String] {
		if path == "/" {
			return ["/"]
		}
		var components = path.pathSegments()
		if isAbsolute {
			components.removeFirst()
			components.insert("/", at: 0)
		}
		return components
	}

	public var lastPathComponent: String {
		return pathComponents.last ?? ""
	}

	public var pathExtension: String {
		let extensionComponents = lastPathComponent.segments(separatedBy: ".")
		guard extensionComponents.count > 1, let lastExtensionComponent = extensionComponents.last, !lastExtensionComponent.isEmpty, !lastExtensionComponent.unicodeScalars.contains(" ") else {
			return ""
		}
		return lastExtensionComponent
	}

	public init(_ path: String) {
		self.path = path.standardizedPath()
	}

	public func appendingPathComponent(_ pathComponent: String) -> CloudPath {
		if !path.isEmpty, path.unicodeScalars.last != "/", pathComponent.unicodeScalars.first != "/" {
			return CloudPath(path + "/" + pathComponent)
		} else {
			return CloudPath(path + pathComponent)
		}
	}

	public func deletingLastPathComponent() -> CloudPath {
		var components = pathComponents
		let lastComponent = components.removeLast()
		if lastComponent == "/" {
			return CloudPath("/..")
		} else if lastComponent == "." {
			return CloudPath("..")
		} else if lastComponent == ".." {
			components.append("..")
			components.append("..")
		}
		return CloudPath(components.joined(separator: "/"))
	}

	public func appendingPathExtension(_ pathExtension: String) -> CloudPath {
		if pathExtension.isEmpty || pathExtension.unicodeScalars.contains(" ") || pathExtension.unicodeScalars.contains("/") || pathExtension.unicodeScalars.last == "." {
			return self
		}
		var components = path.pathSegments()
		let lastComponent = components.removeLast()
		components.append("\(lastComponent).\(pathExtension)")
		return CloudPath(components.joined(separator: "/"))
	}

	public func deletingPathExtension() -> CloudPath {
		var components = path.pathSegments()
		let lastComponent = components.removeLast()
		if lastComponent.isEmpty || lastComponent == "." || lastComponent == ".." {
			return self
		}
		var extensionComponents = lastComponent.segments(separatedBy: ".")
		let lastExtensionComponent = extensionComponents.removeLast()
		if extensionComponents.isEmpty || lastExtensionComponent.isEmpty {
			return self
		}
		components.append(extensionComponents.joined(separator: "."))
		return CloudPath(components.joined(separator: "/"))
	}
}

extension CloudPath {
	static var root: CloudPath {
		return CloudPath("/")
	}

	/// Whether the path is the root or absolute with every component below the root naming one item, i.e., not empty, `.` or `..`. Only such a path reaches the root by removing its last component and resolves to the item it names. A decoded path keeps its spelling, unlike one built with `init(_:)`.
	var isResolvable: Bool {
		return self == .root || isAbsolute && pathComponents.dropFirst().allSatisfy(\.isSinglePathComponent)
	}

	func checkResolvable() throws {
		guard isResolvable else {
			throw CloudProviderError.invalidPath
		}
	}

	/// Throws `CloudProviderError.itemAlreadyExists` for the root, which no operation creates or replaces, and `CloudProviderError.invalidPath` for any other path that isn't `isResolvable`.
	func checkAsTarget() throws {
		guard self != .root else {
			throw CloudProviderError.itemAlreadyExists
		}
		try checkResolvable()
	}

	/// Throws `CloudProviderError.itemTypeMismatch` for the root and `CloudProviderError.invalidPath` for any other path that isn't `isResolvable`. No file operation takes the root, and a folder operation on it would act on everything below it.
	func checkAsSource() throws {
		guard self != .root else {
			throw CloudProviderError.itemTypeMismatch
		}
		try checkResolvable()
	}
}
