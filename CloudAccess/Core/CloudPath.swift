//
//  CloudPath.swift
//  CloudAccess
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
}

extension String {
	func trimmingLeadingCharacters(in set: CharacterSet) -> String {
		var string = self
		while let range = string.rangeOfCharacter(from: set, options: [.anchored]) {
			string = String(string[range.upperBound...])
		}
		return string
	}

	func trimmingTrailingCharacters(in set: CharacterSet) -> String {
		var string = self
		while let range = string.rangeOfCharacter(from: set, options: [.anchored, .backwards]) {
			string = String(string[..<range.lowerBound])
		}
		return string
	}
}

private extension Array where Element == String {
	func standardized() -> [String] {
		var standardized: [String] = []
		for element in self {
			if element.isEmpty || element == "." {
				continue
			} else if let lastElement = standardized.last, lastElement != "..", element == ".." {
				standardized.removeLast()
			} else {
				standardized.append(element)
			}
		}
		if let isAbsolute = first?.isEmpty, isAbsolute {
			standardized.insert("", at: 0)
		}
		return standardized
	}
}

/**
 `CloudPath` is a type that contains the location of a resource on a remote server, the path of a local file on disk, or even an arbitrary piece of encoded data.

 This type mimics the behavior of `URL` but does not implement it and has a reduced set of methods. E.g., a `CloudPath` is not bound to a certain cloud provider or file system and the same path can be used for different providers.
 */
public struct CloudPath: Equatable {
	public let path: String

	public var isAbsolute: Bool {
		return path.first == "/"
	}

	public var hasDirectoryPath: Bool {
		return path.last == "/"
	}

	public var pathComponents: [String] {
		let sanitizedPath = path.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
		let trimmedPath = sanitizedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
		if trimmedPath.isEmpty, isAbsolute {
			return ["/"]
		}
		var components = trimmedPath.components(separatedBy: "/")
		if isAbsolute {
			components.insert("/", at: 0)
		}
		return components
	}

	public var lastPathComponent: String {
		return pathComponents.last ?? ""
	}

	public var standardized: CloudPath {
		let standardizedPathComponents = path.components(separatedBy: "/").standardized()
		return CloudPath(standardizedPathComponents.joined(separator: "/"))
	}

	public init(_ path: String) {
		self.path = path
	}

	public func appendingPathComponent(_ pathComponent: String) -> CloudPath {
		if !path.isEmpty, !path.hasSuffix("/"), !pathComponent.hasPrefix("/") {
			return CloudPath(path + "/" + pathComponent)
		} else {
			return CloudPath(path + pathComponent)
		}
	}

	public func deletingLastPathComponent() -> CloudPath {
		if path.isEmpty {
			return CloudPath("../")
		} else if path == "/" {
			return CloudPath("/../")
		} else if lastPathComponent == ".." {
			return appendingPathComponent("../")
		}
		let trimmedPath = path.trimmingTrailingCharacters(in: CharacterSet(charactersIn: "/"))
		var components = trimmedPath.components(separatedBy: "/")
		let lastComponent = components.removeLast()
		if components.isEmpty, lastComponent != "." {
			components.append(".")
		}
		if lastComponent.isEmpty || lastComponent == "." {
			components.append("..")
		}
		components.append("")
		return CloudPath(components.joined(separator: "/"))
	}
}
