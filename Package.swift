// swift-tools-version:5.1

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
	"OneDrive/OneDriveAuthenticator.swift"
]

let package = Package(
	name: "CryptomatorCloudAccess",
	platforms: [
		.iOS(.v11)
	],
	products: [
		.library(name: "CryptomatorCloudAccess", targets: ["CryptomatorCloudAccess"]),
		.library(name: "CryptomatorCloudAccessCore", targets: ["CryptomatorCloudAccessCore"])
	],
	dependencies: [
		.package(url: "https://github.com/openid/AppAuth-iOS.git", .upToNextMinor(from: "1.4.0")),
		.package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "0.12.0")),
		.package(url: "https://github.com/phil1995/dropbox-sdk-obj-c.git", .branch("main")),
		.package(url: "https://github.com/google/google-api-objectivec-client-for-rest.git", .upToNextMinor(from: "1.5.0")),
		.package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "4.14.0")),
		.package(url: "https://github.com/google/GTMAppAuth.git", .upToNextMinor(from: "1.2.0")),
		.package(url: "https://github.com/google/gtm-session-fetcher.git", .upToNextMinor(from: "1.5.0")),
		.package(url: "https://github.com/airsidemobile/JOSESwift.git", .upToNextMinor(from: "2.4.0")),
		.package(url: "https://github.com/phil1995/msgraph-sdk-objc-auth.git", .branch("swift-pm")),
		.package(url: "https://github.com/phil1995/msgraph-sdk-objc-models.git", .branch("1.3.0-fixed")),
		.package(url: "https://github.com/phil1995/msgraph-sdk-objc.git", .branch("swift-pm")),
		.package(url: "https://github.com/google/promises.git", .upToNextMinor(from: "2.0.0"))
	],
	targets: [
		.target(
			name: "CryptomatorCloudAccessCore",
			dependencies: [
				"CryptomatorCryptoLib",
				"GRDB",
				"Promises",
				"GoogleAPIClientForREST_Drive",
				"GTMAppAuth",
				"GTMSessionFetcher",
				"JOSESwift",
				"MSGraphClientSDK",
				"MSGraphClientModels",
				"MSGraphMSALAuthProvider",
				"ObjectiveDropboxOfficial"
			],
			path: "Sources/CryptomatorCloudAccess",
			exclude: appExtensionUnsafeSources
		),
		.target(
			name: "CryptomatorCloudAccess",
			dependencies: ["CryptomatorCloudAccessCore", "AppAuth"],
			sources: appExtensionUnsafeSources
		),
		.testTarget(
			name: "CryptomatorCloudAccessTests",
			dependencies: ["CryptomatorCloudAccess"]
		)
	],
	swiftLanguageVersions: [.v5]
)
