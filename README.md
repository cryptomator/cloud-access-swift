[![Swift Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcryptomator%2Fcloud-access-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/cryptomator/cloud-access-swift)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcryptomator%2Fcloud-access-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/cryptomator/cloud-access-swift)
[![Codacy Code Quality](https://app.codacy.com/project/badge/Grade/35951085e6604f9aaab998fc65dd2467)](https://www.codacy.com/gh/cryptomator/cloud-access-swift/dashboard)
[![Codacy Coverage](https://app.codacy.com/project/badge/Coverage/35951085e6604f9aaab998fc65dd2467)](https://www.codacy.com/gh/cryptomator/cloud-access-swift/dashboard)

# Cloud Access Swift

This library defines the cloud access API used by Cryptomator for iOS.

The API is implemented once for each cloud. It also forms the foundation for decoration layers for the various vault formats that can be applied to get a cleartext view for cloud-stored vaults.

## Requirements

- iOS 14.0 or higher
- Swift 5

## Installation

### Swift Package Manager

You can use [Swift Package Manager](https://swift.org/package-manager/ "Swift Package Manager").

```swift
.package(url: "https://github.com/cryptomator/cloud-access-swift.git", .upToNextMinor(from: "1.7.0"))
```

## Usage

### Core

The core package contains several protocols, structs, and enums that build the foundation of this library. Asynchronous calls are implemented using the [Promises](https://github.com/google/promises/) library. `CloudProvider` is the main protocol that defines the cloud access:

```swift
func fetchItemMetadata(at cloudPath: CloudPath) -> Promise<CloudItemMetadata>
func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) -> Promise<CloudItemList>
func downloadFile(from cloudPath: CloudPath, to localURL: URL, onTaskCreation: ((URLSessionDownloadTask?) -> Void)?) -> Promise<Void>
func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, onTaskCreation: ((URLSessionUploadTask?) -> Void)?) -> Promise<CloudItemMetadata>
func createFolder(at cloudPath: CloudPath) -> Promise<Void>
func deleteFile(at cloudPath: CloudPath) -> Promise<Void>
func deleteFolder(at cloudPath: CloudPath) -> Promise<Void>
func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void>
func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) -> Promise<Void>
```

### Crypto

A vault provider decorates a cloud provider and allows transparent access to vaults based on Cryptomator's encryption scheme. It depends on [cryptolib-swift](https://github.com/cryptomator/cryptolib-swift) for cryptographic functions and [GRDB](https://github.com/groue/GRDB.swift) for thread-safe caching. For more information on the Cryptomator encryption scheme, visit the security architecture page on [docs.cryptomator.org](https://docs.cryptomator.org/en/1.6/security/architecture/).

In order to create a vault provider, you need a `Masterkey` instance from cryptolib-swift. Check out its documentation on how to create a masterkey. And since vault format 8, you also need a `UnverifiedVaultConfig` instance:

```swift
let provider = ... // any other cloud provider
let vaultPath = ...
let masterkey = ...
let token = ...
let unverifiedVaultConfig = try UnverifiedVaultConfig(token: token)
let cryptoDecorator = try VaultProviderFactory.createVaultProvider(from: unverifiedVaultConfig, masterkey: masterkey, vaultPath: vaultPath, with: provider)
```

And to create a legacy vault provider for vault version 6 or 7:

```swift
let provider = ... // any other cloud provider
let vaultVersion = ... // use `version` from the `MasterkeyFile` instance
let vaultPath = ...
let masterkey = ...
let cryptoDecorator = try VaultProviderFactory.createLegacyVaultProvider(from: masterkey, vaultVersion: vaultVersion, vaultPath: vaultPath, with: provider)
```

:warning: This library supports vault version 6 and higher.

### Dropbox

Set up the `Info.plist` as described in the [official Dropbox Objective-C SDK](https://github.com/dropbox/dropbox-sdk-obj-c). In addition, the following constants must be set once, e.g. in your app delegate:

```swift
let appKey = ... // your Dropbox app key
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `DropboxProvider` in an app extension and set `forceForegroundSession = false`
let keychainService = ... // the service name for the keychain, use `nil` to use default
let forceForegroundSession = ... // if set to `true`, all network requests are made on foreground sessions (by default, most download/upload operations are performed with a background session)
DropboxSetup.constants = DropboxSetup(appKey: appKey, sharedContainerIdentifier: sharedContainerIdentifier, keychainService: keychainService, forceForegroundSession: forceForegroundSession)
```

Begin the authentication flow:

```swift
let dropboxAuthenticator = DropboxAuthenticator()
let viewController = ... // the presenting `UIViewController`
dropboxAuthenticator.authenticate(from: viewController).then { credential in
  // do something with `DropboxCredential`
  // you probably want to save `credential.tokenUID` to re-create the credential later
}.catch { error in
  // error handling
}
```

Handle redirection once the authentication flow is complete in your app delegate:

```swift
func application(_: UIApplication, open url: URL, options _: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
  let canHandle = DBClientsManager.handleRedirectURL(url) { authResult in
    guard let authResult = authResult else {
      return
    }
    if authResult.isSuccess() {
      let tokenUID = authResult.accessToken.uid
      let credential = DropboxCredential(tokenUID: tokenUID)
      DropboxAuthenticator.pendingAuthentication?.fulfill(credential)
      } else if authResult.isCancel() {
        DropboxAuthenticator.pendingAuthentication?.reject(DropboxAuthenticatorError.userCanceled)
      } else if authResult.isError() {
        DropboxAuthenticator.pendingAuthentication?.reject(authResult.nsError)
      }
    }
  return canHandle
}
```

Create a Dropbox provider with a credential:

```swift
let tokenUID = ... // the `tokenUID` you saved after the successful authentication flow
let credential = DropboxCredential(tokenUID: tokenUID)
let provider = DropboxCloudProvider(credential: credential)
```

### Google Drive

Modify your app delegate as described in [AppAuth](https://github.com/openid/AppAuth-iOS). In addition, the following constants must be set once, e.g. in your app delegate:

```swift
let clientId = ... // your Google Drive client identifier
let redirectURL = ...
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `GoogleDriveProvider` with a background `URLSession` in an app extension 
GoogleDriveSetup.constants = GoogleDriveSetup(clientId: clientId, redirectURL: redirectURL, sharedContainerIdentifier: sharedContainerIdentifier)
```

Begin the authentication flow:

```swift
let tokenUID = ... // optional: you might want to give this credential an identifier, defaults to a random UUID
let credential = GoogleDriveCredential(tokenUID: tokenUID)
let viewController = ... // the presenting `UIViewController`
GoogleDriveAuthenticator.authenticate(credential: credential, from: viewController).then { 
  // authentication successful
}.catch { error in
  // error handling
}
```

You can then use the credential to create a Google Drive provider:

```swift
let useBackgroundSession = ... // optional: only needed if you want to create a `GoogleDriveProvider` with a background `URLSession`, defaults to `false`
let provider = GoogleDriveCloudProvider(credential: credential, useBackgroundSession: useBackgroundSession)
```

### OneDrive

Set up the `Info.plist` and your app delegate as described in [MSAL](https://github.com/AzureAD/microsoft-authentication-library-for-objc). In addition, the following constants must be set once, e.g. in your app delegate:

```swift
OneDriveSetup.sharedContainerIdentifier = ... // optional: only needed if you want to create a `OneDriveProvider` with a background `URLSession` in an app extension
OneDriveSetup.clientApplication = ... // your `MSALPublicClientApplication`
```

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
OneDriveAuthenticator.authenticate(from: viewController).then { credential in
  // do something with `OneDriveCredential`
  // you probably want to save `credential.identifier` to re-create the credential later
}.catch { error in
  // error handling
}
```

You can then use the credential to create a OneDrive provider:

```swift
let useBackgroundSession = ... // optional: only needed if you want to create a `OneDriveProvider` with a background `URLSession`, defaults to `false`
let provider = OneDriveCloudProvider(credential: credential, useBackgroundSession: useBackgroundSession)
```

### pCloud

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
PCloudAuthenticator.authenticate(from: viewController).then { credential in
  // do something with `PCloudCredential`
  // you probably want to save `credential.user` to re-create the credential later
}.catch { error in
  // error handling
}
```

You can then use the credential to create a pCloud provider.

Create a pCloud provider with a pCloud client:

```swift
let client = PCloud.createClient(with: credential.user)
let provider = PCloudCloudProvider(client: client)
```

Create a pCloud provider with a pCloud client using a background URLSession:

```swift
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `PCloudCloudProvider` in an app extension 
let client = PCloud.createBackgroundClient(with: credential.user, sharedContainerIdentifier: sharedContainerIdentifier)
let provider = PCloudCloudProvider(client: client)
```

### S3

Create a S3 credential:

```swift
let accessKey = ...
let secretKey = ...
let url = ... // Note: the URL should not already contain the bucket name
let bucket = ... // Note: the bucket should already exist
let region = ...
let identifier = ... // optional: you might want to give this credential an identifier, defaults to a random UUID
let credential = S3Credential(accessKey: accessKey, secretKey: secretKey, url: url, bucket: bucket, region: region, identifier: identifier)
```

You can then use the credential to create a S3 provider.

Create a S3 provider with a S3 credential:

```swift
let provider = try S3Provider(credential: credential)
```

Create a S3 provider using a background URLSession:

```swift
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `S3CloudProvider` in an app extension 
let provider = try S3CloudProvider.withBackgroundSession(credential: credential, sharedContainerIdentifier: sharedContainerIdentifier)
```

In theory, you could use the provider without further checks. However, you should verify the S3 credential using the S3 authenticator:

```swift
let credential = ...
S3Authenticator.verifyCredential(credential).then {
  // credential validation successful
}.catch { error in
  // error handling
}
```

### WebDAV

Create a WebDAV credential:

```swift
let baseURL = ...
let username = ...
let password = ...
let allowedCertificate = ... // optional: you might want to allowlist a TLS certificate
let identifier = ... // optional: you might want to give this credential an identifier, defaults to a random UUID
let credential = WebDAVCredential(baseURL: baseURL, username: username, password: password, allowedCertificate: allowedCertificate, identifier: identifier)
```

You can then use the credential to create a WebDAV provider.

Create a WebDAV provider with a WebDAV client:

```swift
let client = WebDAVClient(credential: credential)
let provider = WebDAVProvider(with: client)
```

Create a WebDAV provider with a WebDAV client using a background URLSession:

```swift
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `WebDAVProvider` in an app extension 
let client = WebDAVClient.withBackgroundSession(credential: credential, sharedContainerIdentifier: sharedContainerIdentifier)
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
let validator = TLSCertificateValidator(baseURL: baseURL)
validator.validate().then { certificate in
  // certificate of type `TLSCertificate` contains several properties for further handling
}.catch { error in
  // error handling
}
```

### Local File System

Since the local file system is not actually a cloud, the naming might be confusing. However, iCloud Drive can be accessed via the local file system and this provider contains code to handle offloaded items.

Create a local file system provider with a root URL:

```swift
let rootURL = ... // rootURL.isFileURL must be `true`
let provider = LocalFileSystemProvider(rootURL: rootURL)
```

When calling the functions of this provider, the cloud paths should be provided relative to the root URL.

This provider uses `NSFileCoordinator` for its operations and supports asynchronous access.

## Logging

This SDK utilizes [CocoaLumberjack](https://github.com/CocoaLumberjack/CocoaLumberjack) for logging. CocoaLumberjack is a flexible, fast, open source logging framework. It supports many capabilities including the ability to set logging level per output target, for instance, concise messages logged to the console and verbose messages to a log file.

CocoaLumberjack logging levels are additive such that when the level is set to verbose, all messages from the levels below verbose are logged. It is also possible to set custom logging to meet your needs. For more information, see [CocoaLumberjack](https://github.com/CocoaLumberjack/CocoaLumberjack/blob/master/Documentation/CustomLogLevels.md).

### Changing Log Levels

```swift
dynamicCloudAccessLogLevel = .verbose
```

The following logging level options are available:

- `.off`
- `.error`
- `.warning`
- `.info`
- `.debug`
- `.verbose`
- `.all`

### Targeting Log Output

Defining the log output targets works the same as with `CocoaLumberjack`, with the only difference that the loggers are added with `CloudAccessDDLog.add()` instead of `DDLog.add()`.
For example:

```swift
CloudAccessDDLog.add(DDOSLogger.sharedInstance) // Uses os_log

let fileLogger: DDFileLogger = DDFileLogger() // File Logger
fileLogger.rollingFrequency = 60 * 60 * 24 // 24 hours
fileLogger.logFileManager.maximumNumberOfLogFiles = 7
CloudAccessDDLog.add(fileLogger)
```

## Integration Tests

You can learn more about cloud provider integration tests [here](Tests/CryptomatorCloudAccessIntegrationTests/README.md).

## Contributing

Please read our [contribution guide](.github/CONTRIBUTING.md), if you would like to report a bug, ask a question or help us with coding.

This project uses [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) and [SwiftLint](https://github.com/realm/SwiftLint) to enforce code style and conventions. Install these tools if you haven't already.

Please make sure that your code is correctly formatted and passes linter validations. The easiest way to do that is to set up a pre-commit hook. Create a file at `.git/hooks/pre-commit` with this content:

```sh
./Scripts/process.sh --staged
exit $?
```

And make your pre-commit hook executable:

```sh
chmod +x .git/hooks/pre-commit
```

## Code of Conduct

Help us keep Cryptomator open and inclusive. Please read and follow our [Code of Conduct](.github/CODE_OF_CONDUCT.md).

## License

This project is dual-licensed under the AGPLv3 for FOSS projects as well as a commercial license derived from the LGPL for independent software vendors and resellers. If you want to use this library in applications that are *not* licensed under the AGPL, feel free to contact our [sales team](https://cryptomator.org/enterprise/).
