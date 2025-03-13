// swift-tools-version:5.7

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
	"Box/BoxAuthenticator.swift"
]

let package = Package(
	name: "CryptomatorCloudAccess",
	platforms: [
		.iOS(.v14)
	],
	products: [
		.library(name: "CryptomatorCloudAccess", targets: ["CryptomatorCloudAccess"]),
		.library(name: "CryptomatorCloudAccessCore", targets: ["CryptomatorCloudAccessCore"])
	],
	dependencies: [
		.package(url: "https://github.com/AzureAD/microsoft-authentication-library-for-objc.git", .upToNextMinor(from: "1.5.0")),
		.package(url: "https://github.com/aws-amplify/aws-sdk-ios-spm.git", .upToNextMinor(from: "2.35.0")),
		.package(url: "https://github.com/cryptomator/cryptolib-swift.git", .upToNextMinor(from: "1.1.0")),
		.package(url: "https://github.com/CocoaLumberjack/CocoaLumberjack.git", .upToNextMinor(from: "3.8.0")),
		.package(url: "https://github.com/google/google-api-objectivec-client-for-rest.git", .upToNextMinor(from: "3.4.0")),
		.package(url: "https://github.com/google/GTMAppAuth.git", .upToNextMinor(from: "4.1.0")),
		.package(url: "https://github.com/google/gtm-session-fetcher.git", .upToNextMinor(from: "3.5.0")),
		.package(url: "https://github.com/google/promises.git", .upToNextMinor(from: "2.3.0")),
		.package(url: "https://github.com/groue/GRDB.swift.git", .upToNextMinor(from: "6.29.1")),
		.package(url: "https://github.com/openid/AppAuth-iOS.git", .upToNextMinor(from: "1.7.0")),
		.package(url: "https://github.com/pCloud/pcloud-sdk-swift.git", .upToNextMinor(from: "3.2.0")),
		.package(url: "https://github.com/phil1995/dropbox-sdk-obj-c-spm.git", .upToNextMinor(from: "7.2.0")),
		.package(url: "https://github.com/phil1995/msgraph-sdk-objc-spm.git", .upToNextMinor(from: "1.0.0")),
		.package(url: "https://github.com/phil1995/msgraph-sdk-objc-models-spm.git", .upToNextMinor(from: "1.3.0")),
		.package(url: "https://github.com/tobihagemann/box-swift-sdk-gen.git", exact: "0.5.0-cryptomator"),
		.package(url: "https://github.com/tobihagemann/JOSESwift.git", exact: "2.4.1-cryptomator")
	],
	targets: [
		.target(
			name: "CryptomatorCloudAccessCore",
			dependencies: [
				.product(name: "AWSCore", package: "aws-sdk-ios-spm"),
				.product(name: "AWSS3", package: "aws-sdk-ios-spm"),
				.product(name: "BoxSdkGen", package: "box-swift-sdk-gen"),
				.product(name: "CocoaLumberjackSwift", package: "CocoaLumberjack"),
				.product(name: "CryptomatorCryptoLib", package: "cryptolib-swift"),
				.product(name: "GoogleAPIClientForREST_Drive", package: "google-api-objectivec-client-for-rest"),
				.product(name: "GRDB", package: "GRDB.swift"),
				.product(name: "GTMAppAuth", package: "GTMAppAuth"),
				.product(name: "GTMSessionFetcher", package: "gtm-session-fetcher"),
				.product(name: "JOSESwift", package: "JOSESwift"),
				.product(name: "MSAL", package: "microsoft-authentication-library-for-objc"),
				.product(name: "MSGraphClientModels", package: "msgraph-sdk-objc-spm"),
				.product(name: "MSGraphClientSDK", package: "msgraph-sdk-objc-models-spm"),
				.product(name: "ObjectiveDropboxOfficial", package: "dropbox-sdk-obj-c-spm"),
				.product(name: "PCloudSDKSwift", package: "pcloud-sdk-swift"),
				.product(name: "Promises", package: "promises")
			],
			path: "Sources/CryptomatorCloudAccess",
			exclude: appExtensionUnsafeSources
		),
		.target(
			name: "CryptomatorCloudAccess",
			dependencies: ["CryptomatorCloudAccessCore", .product(name: "AppAuth", package: "AppAuth-iOS")],
			sources: appExtensionUnsafeSources
		),
		.testTarget(
			name: "CryptomatorCloudAccessTests",
			dependencies: ["CryptomatorCloudAccess"]
		)
	],
	swiftLanguageVersions: [.v5]
)
