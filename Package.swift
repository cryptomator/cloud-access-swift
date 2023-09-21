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
	"OneDrive/OneDriveAuthenticator.swift",
	"PCloud/PCloudAuthenticator.swift"
]

let package = Package(
	name: "CryptomatorCloudAccess",
	platforms: [
		.iOS(.v13)
	],
	products: [
		.library(name: "CryptomatorCloudAccess", targets: ["CryptomatorCloudAccess"]),
		.library(name: "CryptomatorCloudAccessCore", targets: ["CryptomatorCloudAccessCore"])
	],
	dependencies: [
		.package(url: "https://github.com/tobihagemann/JOSESwift.git", .branch("feature/cryptomator")),
		.package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc.git", .exact("1.2.5")),
		.package(url: "https://github.com/aws-amplify/aws-sdk-ios-spm.git", .upToNextMinor(from: "2.30.0")),
		.package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "1.1.0")),
		.package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", .upToNextMinor(from: "3.8.0")),
		.package(url: "https://github.com/google/google-api-objectivec-client-for-rest.git", .upToNextMinor(from: "3.0.0")),
		.package(url: "https://github.com/google/GTMAppAuth.git", .upToNextMinor(from: "2.0.0")),
		.package(url: "https://github.com/google/gtm-session-fetcher.git", .upToNextMinor(from: "3.0.0")),
		.package(url: "https://github.com/google/promises.git", .upToNextMinor(from: "2.0.0")),
		.package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "5.26.0")),
		.package(url: "https://github.com/openid/AppAuth-iOS.git", .upToNextMinor(from: "1.6.0")),
		.package(url: "https://github.com/pCloud/pcloud-sdk-swift.git", .upToNextMinor(from: "3.2.0")),
		.package(url: "https://github.com/phil1995/dropbox-sdk-obj-c-spm.git", .upToNextMinor(from: "7.0.0")),
		.package(url: "https://github.com/phil1995/msgraph-sdk-objc-spm.git", .upToNextMinor(from: "1.0.0")),
		.package(url: "https://github.com/phil1995/msgraph-sdk-objc-models-spm.git", .upToNextMinor(from: "1.3.0"))
	],
	targets: [
		.target(
			name: "CryptomatorCloudAccessCore",
			dependencies: [
				"AWSCore",
				"AWSS3",
				"CocoaLumberjackSwift",
				"CryptomatorCryptoLib",
				"GoogleAPIClientForREST_Drive",
				"GRDB",
				"GTMAppAuth",
				"GTMSessionFetcher",
				"JOSESwift",
				"MSAL",
				"MSGraphClientModels",
				"MSGraphClientSDK",
				"ObjectiveDropboxOfficial",
				"PCloudSDKSwift",
				"Promises"
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
