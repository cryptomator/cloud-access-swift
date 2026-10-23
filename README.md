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
- **`onTaskCreation`:** Gets called at most once with the suspended `URLSessionTask`, and only if the provider transfers the whole file with a single one. The WebDAV, S3, pCloud, Box, Dropbox, Google Drive and Microsoft Graph providers do, also when a vault provider wraps them. Box doesn't for an upload of 50 MiB or more, Dropbox doesn't for one of 150 MiB or more, and Microsoft Graph doesn't for one of more than 5 MiB, because they upload such a file in parts. The provider awaits the closure and then resumes the task itself, so the closure must not resume it. If the calling task is cancelled while the closure runs, the provider never resumes the task, unless it is the task of an upload that passed its commit point before.

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

### Setups

The providers that need the app's registration at the cloud service take it as a setup value: `BoxSetup`, `DropboxSetup`, `GoogleDriveSetup`, `MicrosoftGraphSetup` and `PCloudSetup`. The library keeps no global configuration, so pass the setup wherever a credential or a login is created. Create the setups once per process, e.g., in your app delegate and in each extension, with equal values in every process.

### Background Sessions

Every network provider can run its downloads and uploads on a background URLSession, created with `withBackgroundSession(credential:…, sessionIdentifier:sharedContainerIdentifier:)`. Its other requests run on a foreground URLSession. In an app extension, pass the identifier of a container that the extension shares with the app as `sharedContainerIdentifier`, and `nil` in the app. Use a session identifier of its own for each account, because the providers created with an identifier share one session, configured by the first of them.

### OAuth Persistence

The library keeps the OAuth logins of Box, Dropbox, Google Drive and pCloud, and refreshes the tokens of those that expire. Create one `OAuthPersistence` and pass it to the setup of each of these providers. Every process that uses the same logins, e.g., the app and its extensions, must create it with the same values:

```swift
let accessGroup = ... // optional: the keychain access group of the logins, `nil` for the first group of the `keychain-access-groups` entitlement
let tokenLockDirectory = ... // a directory in the App Group container, the same in the app and every extension
let boxService = ... // the keychain service in which your app kept its Box logins so far; without `services`, Box logins go to `CryptomatorCloudAccess.OAuth.box`
let dropboxService = ... // the keychain service in which your app kept its Dropbox logins so far: the `keychainService` it passed to SwiftyDropbox (by default its bundle identifier) followed by `.dropbox.authv2`; without `services`, Dropbox logins go to `CryptomatorCloudAccess.OAuth.dropbox`
let pCloudService = ... // the keychain service in which your app kept the pCloud SDK's logins so far; without `services`, pCloud logins go to `CryptomatorCloudAccess.OAuth.pcloud`
let oauth = try OAuthPersistence.keychain(accessGroup: accessGroup, tokenLockDirectory: tokenLockDirectory, services: [.box: boxService, .dropbox: dropboxService, .pCloud: pCloudService])
```

The logins are generic passwords in the keychain. An item that the library adds is accessible after the first unlock on this device only. A Box, Dropbox or pCloud login is the item whose account is the user ID, in the service of `services[.box]`, `services[.dropbox]` or `services[.pCloud]`. A Google Drive login uses GTMAppAuth's item, with the service `GoogleDriveAuth` followed by the user ID and the account `OAuth`.

Logins stored by the Box SDK, the Dropbox SDKs, GTMAppAuth or the pCloud SDK (its `OAuth.User` as JSON) keep working without a new login. The library rewrites them in its own format when it first saves them. Every refresh happens only while holding a lock in `tokenLockDirectory`, so that no two processes send the same refresh token, which Box accepts only once.

To keep the logins elsewhere, implement `OAuthTokenStorage` and pass it to `OAuthPersistence.custom(storage:tokenLockDirectory:)`. Its documentation describes the contract that the storage must hold to.

### Box

Create the setup, e.g., in your app delegate:

```swift
let clientID = ... // your Box client identifier
let clientSecret = ... // your Box client secret
let oauth = ... // your `OAuthPersistence`
let setup = BoxSetup(clientID: clientID, clientSecret: clientSecret, oauth: oauth)
```

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await BoxAuthenticator.authenticate(from: viewController, setup: setup)
  // do something with `BoxCredential`
  // you probably want to save `credential.userID` to re-create the credential later
} catch {
  // error handling
}
```

Cancelling the task of the call dismisses the sign-in page and ends the call with `CancellationError`.

Re-create a saved credential:

```swift
let credential = try BoxCredential(userID: userID, setup: setup)
```

`try credential.cachedUsername()` returns the account's name without a request, or `nil` until it is known, e.g., for a login stored by the Box SDK. `try await credential.getUsername()` asks Box for it and stores it if it changed.

You can then use the credential to create a Box provider:

```swift
let provider = try BoxCloudProvider(credential: credential)
```

Or create a Box provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // the App Group container in an app extension, `nil` in the app
let provider = try BoxCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
```

To log out, call `try await credential.deauthenticate()`. It deletes the stored login and then revokes its token, which ends only this login. The login is deleted also if the revocation fails.

### Dropbox

Declare `dbapi-2` and `dbapi-8-emm` in the `LSApplicationQueriesSchemes` of your `Info.plist`, so that the login can hand off to the Dropbox app. Also add the URL type `db-<app key>`, to which Dropbox redirects. Then create the setup, e.g., in your app delegate:

```swift
let appKey = ... // your Dropbox app key
let oauth = ... // your `OAuthPersistence`
let setup = DropboxSetup(appKey: appKey, oauth: oauth)
```

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await DropboxAuthenticator.authenticate(from: viewController, setup: setup)
  // do something with `DropboxCredential`
  // you probably want to save `credential.userID` to re-create the credential later
} catch {
  // error handling
}
```

If the Dropbox app is installed, the login continues there, and the Dropbox app redirects back to your app. Otherwise, the login runs in a web authentication session. Pass the redirect of the Dropbox app to the authenticator, e.g., in your app delegate:

```swift
func application(_: UIApplication, open url: URL, options _: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
  return DropboxAuthenticator.handleRedirectURL(url, setup: setup)
}
```

This completes the pending `authenticate(from:setup:)` call. A late redirect of an earlier login doesn't complete it: `handleRedirectURL(_:setup:)` ignores it and returns `false`, and the pending call keeps waiting for its own redirect. Because the redirect may never arrive, you can cancel the task of that call, which ends it with `CancellationError`. If the login runs in a web authentication session instead, cancelling also dismisses it.

Re-create a saved credential, whose user ID is the `uid` of the account:

```swift
let credential = try DropboxCredential(userID: userID, setup: setup)
```

`try credential.cachedUsername()` returns the account's email without a request, or `nil` until it is known, e.g., for a login stored by a Dropbox SDK. `try await credential.getUsername()` asks Dropbox for it and stores it if it changed.

You can then use the credential to create a Dropbox provider:

```swift
let provider = DropboxCloudProvider(credential: credential)
```

Or create a Dropbox provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // the App Group container in an app extension, `nil` in the app
let provider = DropboxCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
```

To log out, call `try await credential.deauthenticate()`. It deletes the stored login and then revokes its tokens, which ends only this login. The login is deleted also if the revocation fails.

### Google Drive

Create the setup, e.g., in your app delegate:

```swift
let clientID = ... // your Google Drive client identifier
let redirectURL = ... // the redirect URL of your client identifier
let oauth = ... // your `OAuthPersistence`
let setup = GoogleDriveSetup(clientID: clientID, redirectURL: redirectURL, oauth: oauth)
```

Begin the authentication flow, which runs in a web authentication session:

```swift
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await GoogleDriveAuthenticator.authenticate(from: viewController, setup: setup)
  // do something with `GoogleDriveCredential`
  // you probably want to save `credential.userID` to re-create the credential later
} catch {
  // error handling
}
```

Cancelling the task of the call dismisses Google's sign-in page and ends the call with `CancellationError`.

Re-create a saved credential:

```swift
let credential = try GoogleDriveCredential(userID: userID, setup: setup)
```

`try credential.cachedUsername()` returns the account's email without a request, or `nil` if it wasn't stored with the login. `try await credential.getUsername()` asks Google for it and stores it if it changed.

You can then use the credential to create a Google Drive provider:

```swift
let provider = try GoogleDriveCloudProvider(credential: credential)
```

Or create a Google Drive provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // the App Group container in an app extension, `nil` in the app
let provider = try GoogleDriveCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
```

To log out, call `try await credential.deauthenticate()`. It deletes the stored login without revoking its token. Google revokes a token for every device and app of the same Google Cloud project, so revoking it would sign the account out elsewhere, too.

### Microsoft Graph

Accessing OneDrive and SharePoint can both be done via Microsoft Graph.

Set up the `Info.plist` and your app delegate as described in [MSAL](https://github.com/AzureAD/microsoft-authentication-library-for-objc). Then create the setup, e.g., in your app delegate:

```swift
let clientApplication = ... // your `MSALPublicClientApplication`
let setup = MicrosoftGraphSetup(clientApplication: clientApplication)
```

In this example, we will use OneDrive. You can also use SharePoint by replacing `.oneDrive` with `.sharePoint` in the following code snippets. Internally, the only difference is the scopes that are requested.

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await MicrosoftGraphAuthenticator.authenticate(from: viewController, for: .oneDrive, setup: setup)
  // do something with `MicrosoftGraphCredential`
  // you probably want to save `credential.identifier` to re-create the credential later
} catch {
  // error handling
}
```

Cancelling the task of the call while Microsoft's sign-in sheet is shown dismisses it and ends the call with `CancellationError`.

Re-create a saved credential:

```swift
let credential = MicrosoftGraphCredential(identifier: identifier, type: .oneDrive, setup: setup)
```

You can then use the credential to create a Microsoft Graph provider:

```swift
let provider = try MicrosoftGraphCloudProvider(credential: credential)
```

Or create a Microsoft Graph provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // the App Group container in an app extension, `nil` in the app
let provider = try MicrosoftGraphCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
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

Create the setup, e.g., in your app delegate:

```swift
let appKey = ... // your pCloud app key
let oauth = ... // your `OAuthPersistence`
let setup = PCloudSetup(appKey: appKey, oauth: oauth)
```

Begin the authentication flow:

```swift
let viewController = ... // the presenting `UIViewController`
do {
  let credential = try await PCloudAuthenticator.authenticate(from: viewController, setup: setup)
  // do something with `PCloudCredential`
  // you probably want to save `credential.userID` to re-create the credential later
} catch {
  // error handling
}
```

Cancelling the task of the call dismisses the sign-in page and ends the call with `CancellationError`.

Re-create a saved credential:

```swift
let credential = try PCloudCredential(userID: userID, setup: setup)
```

`try credential.cachedUsername()` returns the account's email without a request, or `nil` until it is known, e.g., for a login stored by the pCloud SDK. `try await credential.getUsername()` asks pCloud for it and stores it if it changed.

You can then use the credential to create a pCloud provider:

```swift
let provider = try PCloudCloudProvider(credential: credential)
```

Or create a pCloud provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // the App Group container in an app extension, `nil` in the app
let provider = try PCloudCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
```

To log out, call `try await credential.deauthenticate()`. It deletes the stored login, after which every process's provider of the account throws `CloudProviderError.unauthorized`. pCloud offers no revocation of an OAuth token, so the token itself stays valid.

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

Or create a S3 provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // the App Group container in an app extension, `nil` in the app
let provider = try S3CloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
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

You can then use the credential to create a WebDAV provider:

```swift
let provider = try WebDAVCloudProvider(credential: credential)
```

Or create a WebDAV provider whose downloads and uploads run on a background URLSession:

```swift
let sessionIdentifier = ...
let sharedContainerIdentifier = ... // the App Group container in an app extension, `nil` in the app
let provider = try WebDAVCloudProvider.withBackgroundSession(credential: credential, sessionIdentifier: sessionIdentifier, sharedContainerIdentifier: sharedContainerIdentifier)
```

In theory, you could use the provider without further checks. However, you should verify the WebDAV credential using the WebDAV authenticator:

```swift
let credential = ...
do {
  try await WebDAVAuthenticator.verifyCredential(credential)
  // credential validation successful
} catch WebDAVError.httpError(statusCode: 401) {
  // the server rejected the credential
} catch {
  // error handling
}
```

A failed WebDAV request throws `WebDAVError.httpError(statusCode:)` for a status other than 2xx, and `WebDAVError.unexpectedResponse` for a response it can't read. The provider maps them to a `CloudProviderError` where one applies.

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
