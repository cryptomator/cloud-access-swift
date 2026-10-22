// swift-tools-version:6.2

//
//  Package.swift
//  CryptomatorCloudAccess
//
//  Created by Philipp Schmid on 24.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import PackageDescription

let appExtensionUnsafeSources = [
	"Dropbox/DropboxAuthenticator.swift",
	"GoogleDrive/GoogleDriveAuthenticator.swift",
	"MicrosoftGraph/MicrosoftGraphAuthenticator.swift",
	"PCloud/PCloudAuthenticator.swift",
	"Box/BoxAuthenticator.swift",
	"OAuth/WebAuthenticationSession.swift"
]

let swiftSettings: [SwiftSetting] = [
	.enableUpcomingFeature("NonisolatedNonsendingByDefault")
]

let package = Package(
	name: "CryptomatorCloudAccess",
	platforms: [
		.iOS(.v17)
	],
	products: [
		.library(name: "CryptomatorCloudAccess", targets: ["CryptomatorCloudAccess"]),
		.library(name: "CryptomatorCloudAccessCore", targets: ["CryptomatorCloudAccessCore"])
	],
	dependencies: [
		.package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc.git", exact: "2.16.0"),
		.package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "3.0.0")),
		.package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", .upToNextMinor(from: "3.10.0")),
		.package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "7.11.1")),
		.package(url: "https://github.com/openid/AppAuth-iOS.git", .upToNextMinor(from: "3.0.0")),
		.package(url: "https://github.com/cryptomator/JOSESwift.git", exact: "3.0.0-cryptomator.2")
	],
	targets: [
		.target(
			name: "CryptomatorCloudAccessCore",
			dependencies: [
				.product(name: "AppAuthCore", package: "AppAuth-iOS"),
				.product(name: "CocoaLumberjackSwift", package: "CocoaLumberjack"),
				.product(name: "CryptomatorCryptoLib", package: "cryptolib-swift"),
				.product(name: "GRDB", package: "GRDB.swift"),
				.product(name: "JOSESwift", package: "JOSESwift"),
				.product(name: "MSAL", package: "microsoft-authentication-library-for-objc")
			],
			path: "Sources/CryptomatorCloudAccess",
			exclude: appExtensionUnsafeSources,
			swiftSettings: swiftSettings
		),
		.target(
			name: "CryptomatorCloudAccess",
			dependencies: ["CryptomatorCloudAccessCore", .product(name: "AppAuth", package: "AppAuth-iOS")],
			sources: appExtensionUnsafeSources,
			swiftSettings: swiftSettings
		),
		.testTarget(
			name: "CryptomatorCloudAccessTests",
			dependencies: ["CryptomatorCloudAccess"],
			swiftSettings: swiftSettings
		)
	],
	swiftLanguageModes: [.v6]
)
