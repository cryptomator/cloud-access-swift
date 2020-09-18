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

	func standardizedPath() -> String {
		return components(separatedBy: "/").standardized().joined(separator: "/")
	}
}

private extension Array where Element == String {
	subscript(safe index: Index) -> Element? {
		return indices.contains(index) ? self[index] : nil
	}

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
public struct CloudPath: Equatable, Codable {
	public let path: String

	public var isAbsolute: Bool {
		return path.first == "/"
	}

	public var pathComponents: [String] {
		if path == "/" {
			return ["/"]
		}
		var components = path.components(separatedBy: "/")
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
		if !path.isEmpty, !path.hasSuffix("/"), !pathComponent.hasPrefix("/") {
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
		if pathExtension.isEmpty || pathExtension.contains(" ") || pathExtension.contains("/") || pathExtension.last == "." {
			return self
		}
		var components = path.components(separatedBy: "/")
		let lastComponent = components.removeLast()
		components.append("\(lastComponent).\(pathExtension)")
		return CloudPath(components.joined(separator: "/"))
	}

	public func deletingPathExtension() -> CloudPath {
		var components = path.components(separatedBy: "/")
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
