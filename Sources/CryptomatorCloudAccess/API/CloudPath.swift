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

	func appendingPathComponent(_ cloudPath: CloudPath) -> URL {
		let trimmedPath = cloudPath.path.trimmingLeadingCharacters(in: CharacterSet(charactersIn: "/"))
		if trimmedPath.isEmpty {
			return self
		} else {
			return appendingPathComponent(trimmedPath)
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

	/// Splits the string at every slash, keeping empty segments. It compares Unicode scalars, because a slash forms one `Character` with a combining mark after it or a prepended mark (e.g. U+0600) before it, so a `Character`-based search misses it.
	func pathSegments() -> [String] {
		return unicodeScalars.split(separator: "/", omittingEmptySubsequences: false).map { String(Substring($0)) }
	}

	/// Whether appending the string to a cloud path adds exactly one component equal to the string, rather than nesting it, dropping a slash or resolving to the folder or its parent.
	var isSinglePathComponent: Bool {
		return !isEmpty && !unicodeScalars.contains("/") && self != "." && self != ".."
	}
}

private extension [String] {
	subscript(safe index: Index) -> Element? {
		return indices.contains(index) ? self[index] : nil
	}

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
		let lastComponent = lastPathComponent
		if !lastComponent.contains(".") {
			return ""
		}
		let extensionComponents = lastComponent.components(separatedBy: ".")
		guard let lastExtensionComponent = extensionComponents.last else {
			return ""
		}
		if lastExtensionComponent.isEmpty || lastExtensionComponent.contains(" ") {
			return ""
		} else {
			return lastExtensionComponent
		}
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
		if pathExtension.isEmpty || pathExtension.contains(" ") || pathExtension.unicodeScalars.contains("/") || pathExtension.last == "." {
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
		var extensionComponents = lastComponent.components(separatedBy: ".")
		let lastExtensionComponent = extensionComponents.removeLast()
		if extensionComponents.isEmpty || lastExtensionComponent.isEmpty {
			return self
		}
		components.append(extensionComponents.joined(separator: "."))
		return CloudPath(components.joined(separator: "/"))
	}
}
