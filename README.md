[![Swift Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcryptomator%2Fcloud-access-swift%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/cryptomator/cloud-access-swift)
[![Platform Compatibility](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fcryptomator%2Fcloud-access-swift%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/cryptomator/cloud-access-swift)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=cryptomator_cloud-access-swift&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=cryptomator_cloud-access-swift)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=cryptomator_cloud-access-swift&metric=coverage)](https://sonarcloud.io/summary/new_code?id=cryptomator_cloud-access-swift)

# Cloud Access Swift

This library defines the cloud access API used by Cryptomator for iOS.

The API is implemented once for each cloud. It also forms the foundation for decoration layers for the various vault formats that can be applied to get a cleartext view for cloud-stored vaults.

## Special Shoutout

Continuous integration hosting is provided by [MacStadium](https://www.macstadium.com/company/opensource).

<a href="https://www.macstadium.com/company/opensource"><img src="https://uploads-ssl.webflow.com/5ac3c046c82724970fc60918/5c019d917bba312af7553b49_MacStadium-developerlogo.png" alt="MacStadium" height="100"></a>

## Requirements

- iOS 17.0 or higher
- Swift 6.2 or higher

## Installation

### Swift Package Manager

You can use [Swift Package Manager](https://swift.org/package-manager/ "Swift Package Manager").

```swift
.package(url: "https://github.com/cryptomator/cloud-access-swift.git", .upToNextMinor(from: "4.0.0"))
```

## Usage

### Core

The core package contains several protocols, structs, and enums that build the foundation of this library. Asynchronous calls are implemented using Swift concurrency. `CloudProvider` is the main protocol that defines the cloud access:

```swift
func fetchItemMetadata(at cloudPath: CloudPath) async throws -> CloudItemMetadata
func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList
func downloadFile(from cloudPath: CloudPath, to localURL: URL, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionDownloadTask) async -> Void)?) async throws -> CloudItemMetadata
func uploadFile(from localURL: URL, to cloudPath: CloudPath, replaceExisting: Bool, progress: Progress?, onTaskCreation: (@concurrent @Sendable (URLSessionUploadTask) async -> Void)?) async throws -> CloudItemMetadata
func createFolder(at cloudPath: CloudPath) async throws
func deleteFile(at cloudPath: CloudPath) async throws
func deleteFolder(at cloudPath: CloudPath) async throws
func moveFile(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws
func moveFolder(from sourceCloudPath: CloudPath, to targetCloudPath: CloudPath) async throws
```

`CloudProvider` is `Sendable`, so a provider can be shared between tasks. Its methods are `@concurrent`, so they don't run on the caller's actor. `downloadFile` and `uploadFile` can also be called without `progress` and `onTaskCreation`.

- **Cancellation:** Cancellation is cooperative and has no latency guarantee. Every method checks whether its task is cancelled before it starts and again between its steps, and throws `CancellationError` if it is. A request or transfer that is already running is not interrupted. After its commit point, a method no longer checks:
  - A download commits when it creates the file at `localURL`.
  - An upload, folder creation, deletion or move commits with its first remote change after which stopping would break the item, e.g., leave it unreadable or impossible to create again. Without such a change, it commits with its last remote change. From its commit point on, it finishes its remaining remote changes even if the task is cancelled.

  Remote changes are not rolled back. After a call that threw, a remote item that the call was supposed to create, replace, delete or move may or may not exist.
- **Downloads:** The file is created at `localURL` only if the download succeeds. An item that already exists there is not overwritten (`CloudProviderError.itemAlreadyExists`). The returned metadata has the size of the local file and the `lastModifiedDate` that `fetchItemMetadata(at:)` reports, which is never newer than the downloaded content.
- **Progress:** Pass a fresh `Progress` to observe a download or upload. The provider is its exclusive writer and sets its unit counts. The progress completes only when the method returns and stays incomplete if the method throws.
- **`onTaskCreation`:** Gets called at most once with the suspended `URLSessionTask`, and only if the provider transfers the whole file with a single one. Currently, the WebDAV, S3, pCloud and Box providers do, also when a vault provider wraps them. Box doesn't for an upload of 50 MiB or more, because it uploads such a file in parts. The provider awaits the closure and then resumes the task itself, so the closure must not resume it. If the calling task is cancelled while the closure runs, the provider never resumes the task, unless it is the task of an upload that passed its commit point before.

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

### Box

The following constants must be set once, e.g. in your app delegate:

```swift
let clientId = ... // your Box client identifier
let clientSecret = ... // your Box client secret
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `BoxCloudProvider` with a background `URLSession` in an app extension
let tokenLockDirectory = ... // a directory in the App Group container, the same in the app and every extension
BoxSetup.constants = try BoxSetup(clientId: clientId, clientSecret: clientSecret, sharedContainerIdentifier: sharedContainerIdentifier, tokenLockDirectory: tokenLockDirectory)
```

The library keeps the Box tokens in an `OAuthTokenStorage` that your app implements, e.g., over the keychain, with one item per Box user ID. The library decides what the stored bytes contain, and it reads an item that the Box SDK stored, too. Your storage must hold to this contract:

- `load(forAccount:)` returns `nil` only if no item exists and throws for any other failure, e.g., a keychain that is locked.
- Nothing is cached: every load reads the persisted bytes, because other processes write them, too.
- `save(_:forAccount:)` returns after the write completed and replaces an existing item in place.
- Every process that uses the same items passes the same `tokenLockDirectory`. The library refreshes a token only while holding a lock in it, because Box refresh tokens can be used only once.

Begin the authentication flow:

```swift
let tokenStorage = ... // your `OAuthTokenStorage`
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await BoxAuthenticator.authenticate(from: viewController, tokenStorage: tokenStorage)
  // do something with `BoxCredential`
  // you probably want to save `credential.userID` to re-create the credential later
} catch {
  // error handling
}
```

Re-create a saved credential:

```swift
let credential = try BoxCredential(userID: userID, tokenStorage: tokenStorage)
```

You can then use the credential to create a Box provider:

```swift
let provider = try BoxCloudProvider(credential: credential)
```

Or create a Box provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let provider = try BoxCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier)
```

To log out, call `try await credential.deauthenticate()`. It deletes the stored item and then revokes the token. The item is deleted also if the revocation fails.

### Dropbox

Set up the `Info.plist` as described in the [official Dropbox Swift SDK](https://github.com/dropbox/SwiftyDropbox#application-plist-file). In addition, the following constants must be set once, e.g. in your app delegate:

```swift
let appKey = ... // your Dropbox app key
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `DropboxCloudProvider` in an app extension and set `forceForegroundSession = false`
let keychainService = ... // the service name for the keychain, use `nil` to use default
let forceForegroundSession = ... // if set to `true`, all network requests are made on foreground sessions (by default, most download/upload operations are performed with a background session)
DropboxSetup.constants = DropboxSetup(appKey: appKey, sharedContainerIdentifier: sharedContainerIdentifier, keychainService: keychainService, forceForegroundSession: forceForegroundSession)
```

Begin the authentication flow:

```swift
let dropboxAuthenticator = DropboxAuthenticator()
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await dropboxAuthenticator.authenticate(from: viewController)
  // do something with `DropboxCredential`
  // you probably want to save `credential.tokenUID` to re-create the credential later
} catch {
  // error handling
}
```

Handle redirection once the authentication flow is complete in your app delegate:

```swift
func application(_: UIApplication, open url: URL, options _: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
  return DropboxAuthenticator.handleRedirectURL(url)
}
```

This completes the pending `authenticate(from:)` call. Because the redirect may never arrive, you can cancel the task of that call, which ends it with `CancellationError`.

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
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `GoogleDriveCloudProvider` with a background `URLSession` in an app extension 
GoogleDriveSetup.constants = GoogleDriveSetup(clientId: clientId, redirectURL: redirectURL, sharedContainerIdentifier: sharedContainerIdentifier)
```

Begin the authentication flow:

```swift
let userID = ... // optional: the result of `credential.getAccountID()` from an earlier authentication to restore that credential
let credential = GoogleDriveCredential(userID: userID)
let viewController = ... // the presenting `UIViewController`
do {
  try await GoogleDriveAuthenticator.authenticate(credential: credential, from: viewController)
  // authentication successful
} catch {
  // error handling
}
```

You can then use the credential to create a Google Drive provider:

```swift
let provider = try GoogleDriveCloudProvider(credential: credential)
```

Or create a Google Drive provider using a background URLSession:

```swift
let sessionIdentifier = ...
let provider = try GoogleDriveCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier)
```

### Microsoft Graph

Accessing OneDrive and SharePoint can both be done via Microsoft Graph.

Set up the `Info.plist` and your app delegate as described in [MSAL](https://github.com/AzureAD/microsoft-authentication-library-for-objc). In addition, the following constants must be set once, e.g. in your app delegate:

```swift
let clientApplication = ... // your `MSALPublicClientApplication`
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `MicrosoftGraphCloudProvider` with a background `URLSession` in an app extension
MicrosoftGraphSetup.constants = MicrosoftGraphSetup(clientApplication: clientApplication, sharedContainerIdentifier: sharedContainerIdentifier)
```

In this example, we will use OneDrive. You can also use SharePoint by replacing `.oneDrive` with `.sharePoint` in the following code snippet. Internally, the only difference is the scopes that are requested. If you want, you can also request custom scopes by using the method `MicrosoftGraphAuthenticator.authenticate(from viewController: UIViewController, with scopes: [String])`.

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await MicrosoftGraphAuthenticator.authenticate(from: viewController, for: .oneDrive)
  // do something with `MicrosoftGraphCredential`
  // you probably want to save `credential.identifier` to re-create the credential later
} catch {
  // error handling
}
```

You can then use the credential to create a Microsoft Graph provider:

```swift
let provider = try MicrosoftGraphCloudProvider(credential: credential)
```

Or create a Microsoft Graph provider using a background URLSession:

```swift
let sessionIdentifier = ...
let provider = try MicrosoftGraphCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier)
```

For SharePoint, it could be useful to do some discovery first:

```swift
let discovery = MicrosoftGraphDiscovery(credential: credential)
let siteURL = ... // the URL of the SharePoint site
do {
  let site = try await discovery.fetchSharePointSite(for: siteURL)
  // do something with `MicrosoftGraphSite`, e.g.:
  let drives = try await discovery.fetchSharePointDrives(for: site.identifier)
  // do something with `[MicrosoftGraphDrive]`
} catch {
  // error handling
}
```

### pCloud

The following constants must be set once, e.g. in your app delegate:

```swift
let appKey = ... // your pCloud app key
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `PCloudCloudProvider` with a background `URLSession` in an app extension
PCloudSetup.constants = PCloudSetup(appKey: appKey, sharedContainerIdentifier: sharedContainerIdentifier)
```

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await PCloudAuthenticator.authenticate(from: viewController)
  // do something with `PCloudCredential`
  // you probably want to save `credential.id`, `credential.accessToken`, `credential.apiHostName` and `credential.locationID` to re-create the credential later
} catch {
  // error handling
}
```

Re-create a saved credential:

```swift
let credential = try PCloudCredential(id: id, accessToken: accessToken, apiHostName: apiHostName, locationID: locationID)
```

You can then use the credential to create a pCloud provider:

```swift
let provider = try PCloudCloudProvider(credential: credential)
```

Or create a pCloud provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let provider = try PCloudCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier)
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

You can then use the credential to create a S3 provider:

```swift
let provider = try S3CloudProvider(credential: credential)
```

Or create a S3 provider using a background URLSession:

```swift
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `S3CloudProvider` in an app extension 
let provider = try S3CloudProvider.withBackgroundSession(credential: credential, sharedContainerIdentifier: sharedContainerIdentifier)
```

In theory, you could use the provider without further checks. However, you should verify the S3 credential using the S3 authenticator:

```swift
let credential = ...
do {
  try await S3Authenticator.verifyCredential(credential)
  // credential validation successful
} catch {
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

You can then use the credential to create a WebDAV provider with a WebDAV client:

```swift
let client = WebDAVClient(credential: credential)
let provider = try WebDAVProvider(with: client)
```

Or create a WebDAV provider with a WebDAV client using a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // optional: only needed if you want to create a `WebDAVProvider` in an app extension 
let client = WebDAVClient.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
let provider = try WebDAVProvider(with: client)
```

In theory, you could use the provider without further checks. However, you should verify the WebDAV client and its credential using the WebDAV authenticator:

```swift
let client = ...
do {
  try await WebDAVAuthenticator.verifyClient(client: client)
  // client validation successful
} catch {
  // error handling
}
```

Furthermore, for allowlisting a certificate, you can use the TLS certificate validator:

```swift
let baseURL = ...
let validator = TLSCertificateValidator(baseURL: baseURL)
do {
  let certificate = try await validator.validate()
  // certificate of type `TLSCertificate` contains several properties for further handling
} catch {
  // error handling
}
```

### Local File System

Since the local file system is not actually a cloud, the naming might be confusing. However, iCloud Drive can be accessed via the local file system and this provider contains code to handle offloaded items.

Create a local file system provider with a root URL:

```swift
let rootURL = ... // rootURL.isFileURL must be `true`
let provider = try LocalFileSystemProvider(rootURL: rootURL)
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
