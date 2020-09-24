// swift-tools-version:5.0

//
//  Package.swift
//  CloudAccess
//
//  Created by Philipp Schmid on 24.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import PackageDescription

let package = Package(
	name: "CloudAccess",
	platforms: [
		.iOS(.v9)
	],
	products: [
		.library(name: "CloudAccess", targets: ["CloudAccess"])
	],
	dependencies: [
		.package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "0.8.1")),
		.package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "4.14.0")),
		.package(url: "https://github.com/google/promises.git", .upToNextMinor(from: "1.2.0"))
	],
	targets: [
		.target(name: "CloudAccess", dependencies: ["CryptoLib", "GRDB", "Promises"], path: "CloudAccess"),
		.testTarget(name: "CloudAccessTests", dependencies: ["CloudAccess"], path: "CloudAccessTests")
	],
	swiftLanguageVersions: [.v5]
)
