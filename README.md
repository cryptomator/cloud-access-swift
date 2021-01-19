[![Swift Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcryptomator%2Fcloud-access-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/cryptomator/cloud-access-swift)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcryptomator%2Fcloud-access-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/cryptomator/cloud-access-swift)
[![Version](http://img.shields.io/cocoapods/v/CryptomatorCloudAccess.svg)](https://cocoapods.org/pods/CryptomatorCloudAccess)
[![Codacy Code Quality](https://app.codacy.com/project/badge/Grade/35951085e6604f9aaab998fc65dd2467)](https://www.codacy.com/gh/cryptomator/cloud-access-swift)
[![Codacy Coverage](https://app.codacy.com/project/badge/Coverage/35951085e6604f9aaab998fc65dd2467)](https://www.codacy.com/gh/cryptomator/cloud-access-swift)

# Cloud Access Swift

This library defines the cloud access API used by Cryptomator for iOS.

The API is implemented once for each cloud. It also forms the foundation for decoration layers for the various vault formats that can be applied to get a cleartext view for cloud-stored vaults.

## Requirements

- iOS 9.0 or higher
- macOS 10.12 or higher

## Installation

### Swift Package Manager

You can use [Swift Package Manager](https://swift.org/package-manager/ "Swift Package Manager").

```swift
.package(url: "https://github.com/cryptomator/cloud-access-swift.git", .upToNextMinor(from: "1.0.0"))
```

### CocoaPods

You can use [CocoaPods](https://cocoapods.org/ "CocoaPods").

```ruby
pod 'CryptomatorCloudAccess', '~> 1.0.0'
```

## Usage

### Core

The core package contains several protocols, structs, and enums that build the foundation of this library. Asynchronous calls are implemented using the [Promises](https://github.com/google/promises/) library. `CloudProvider` is the main protocol that defines the cloud access:

```swift
func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata>
func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList>
func downloadFile(from cloudPath: CloudPath, to localURL: URL) -> Promise<Void>
func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool) -> Promise<CloudItemMetadata>
func createFolder(at cloudPath: CloudPath) -> Promise<Void>
func deleteFile(at cloudPath: CloudPath) -> Promise<Void>
func deleteFolder(at cloudPath: CloudPath) -> Promise<Void>
func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void>
func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void>
```

### Crypto

Crypto and shortening decorators allow transparent access to vaults based on Cryptomator's encryption scheme. It depends on [cryptolib-swift](https://github.com/cryptomator/cryptolib-swift) for cryptographic functions and [GRDB](https://github.com/groue/GRDB.swift) for thread-safe caching. For more information on the Cryptomator encryption scheme, visit the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.5/security/architecture/).

In order to create a crypto decorator provider, you need a `Cryptor` instance from cryptolib-swift. Check out its documentation on how to create a cryptor. And to be fully compatible, you'd have to put a shortening decorator in-between:

```swift
let provider = ... // any other cloud provider
let vaultPath = ...
...
let cryptor = ...
let shorteningDecorator = try VaultFormat7ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
let cryptoDecorator = try VaultFormat7ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
```

:warning: You have to check the version of your `MasterkeyFile` instance so that you create the correct decorator. This library supports vault version 6 and higher.

### Local File System

Since the local file system is not actually a cloud, the naming might be confusing. Even though this library is dedicated to provide access to many cloud storage services, access to the local file system still might be useful.

Create a local file system provider with a root URL:

```swift
let rootURL = ... // rootURL.isFileURL must be `true`
let provider = LocalFileSystemProvider(rootURL: rootURL)
```

When calling the functions of this provider, the cloud paths should be provided relative to the root URL.

This provider uses `NSFileCoordinator` for its operations and supports asynchronous access.

### WebDAV

Create a WebDAV provider with a WebDAV client:

```swift
let baseURL = ...
let username = ...
let password = ...
let allowedCertificate = ... // optional: you might want to allowlist a TLS certificate
let identifier = ... // optional: you might want to give this credential an identifier, defaults to a random UUID
let credential = WebDAVCredential(baseURL: baseURL, username: username, password: password, allowedCertificate: allowedCertificate, identifier: identifier)
let sharedContainerIdentifier = ... // this will be set internally for the `URLSessionConfiguration`
let useBackgroundSession = ... // if `true`, the internal `URLSessionConfiguration` will be based on a background configuration
let client = WebDAVClient(credential: credential, sharedContainerIdentifier: sharedContainerIdentifier, useBackgroundSession: useBackgroundSession)
let provider = WebDAVProvider(with: client)
```

In theory, you could use the provider without further checks. However, you should verify the WebDAV client and its credential using the WebDAV authenticator:

```swift
let client = ...
WebDAVAuthenticator.verifyClient(client: client).then {
  // client validation successful
}.catch { error in
  // error handling
}
```

Furthermore, for allowlisting a certificate, you can use the TLS certificate validator:

```swift
let baseURL = ...
let sharedContainerIdentifier = ...
let validator = TLSCertificateValidator(baseURL: baseURL, sharedContainerIdentifier: sharedContainerIdentifier)
validator.validate().then { certificate in
  // certificate of type `TLSCertificate` contains several properties for further handling
}.catch { error in
  // error handling
}
```

## Contributing to Cloud Access Swift

Please read our [contribution guide](.github/CONTRIBUTING.md), if you would like to report a bug, ask a question or help us with coding.

## Code of Conduct

Help us keep Cryptomator open and inclusive. Please read and follow our [Code of Conduct](.github/CODE_OF_CONDUCT.md).

## License

Distributed under the AGPLv3. See the LICENSE file for more info.
