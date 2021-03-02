// swift-tools-version:5.1

//
//  Package.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import PackageDescription

let package = Package(
	name: "CryptomatorCloudAccess",
	platforms: [
		.iOS(.v9),
		.macOS(.v10_12)
	],
	products: [
		.library(name: "CryptomatorCloudAccess", targets: ["CryptomatorCloudAccess"])
	],
	dependencies: [
		.package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "0.11.0")),
		.package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "4.14.0")),
		.package(url: "https://github.com/google/promises.git", .upToNextMinor(from: "1.2.0")),
		.package(url: "https://github.com/Kitura/Swift-JWT.git", .upToNextMinor(from: "3.6.0"))
	],
	targets: [
		.target(name: "CryptomatorCloudAccess", dependencies: ["CryptomatorCryptoLib", "GRDB", "Promises", "SwiftJWT"]),
		.testTarget(name: "CryptomatorCloudAccessTests", dependencies: ["CryptomatorCloudAccess"])
	],
	swiftLanguageVersions: [.v5]
)
