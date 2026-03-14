# Integration Tests

Test the individual `CloudProvider` implementations against the live API of the respective cloud.

## Secrets

If you would like to run integration tests that require authentication, you have to set some secrets for them. Create a `.integration-test-secrets.sh` file in the root directory. Its contents should look something like this:

```sh
#!/bin/sh
export BOX_CLIENT_ID=...
export BOX_CLIENT_SECRET=...
export BOX_ENTERPRISE_ID=...
export DROPBOX_ACCESS_TOKEN=...
export GOOGLE_DRIVE_CLIENT_ID=...
export GOOGLE_DRIVE_REFRESH_TOKEN=...
export MICROSOFT_GRAPH_CLIENT_ID=...
export MICROSOFT_GRAPH_REDIRECT_URI_SCHEME=...
export MICROSOFT_GRAPH_REFRESH_TOKEN=...
export PCLOUD_APP_KEY=...
export PCLOUD_ACCESS_TOKEN=...
export PCLOUD_HTTP_API_HOST_NAME=...
export S3_ACCESS_KEY=...
export S3_SECRET_KEY=...
export S3_URL=...
export S3_BUCKET=...
export S3_REGION=...
export WEBDAV_BASE_URL=...
export WEBDAV_USERNAME=...
export WEBDAV_PASSWORD=...
```

If you aren't using the Xcode project, you may have to run `./create-integration-test-secrets-file.sh` once. If you change the secrets later on, you have to run that script again.

If you are building via a CI system, set these secret environment variables accordingly.

### How to Get the Secrets

#### Dropbox

To get the access token for Dropbox, generate a token in the Dropbox Developer Portal. For more detailed instructions, check out the [OAuth Guide from Dropbox](https://developers.dropbox.com/oauth-guide).

#### Google Drive

To get the refresh token for Google Drive, extract it from the keychain after a successful login. The auth session is stored by GTMAppAuth with the item name `GoogleDriveAuth` + user ID. The following method can be used to extract the refresh token:

```swift
import AppAuthCore
import GTMAppAuth

func extractGoogleDriveRefreshToken(userID: String) {
  let store = KeychainStore(itemName: "GoogleDriveAuth" + userID)
  if let authSession = try? store.retrieveAuthSession() {
    print("GOOGLE_DRIVE_REFRESH_TOKEN=\(authSession.authState.refreshToken ?? "nil")")
  }
}
```

#### Microsoft Graph

To get the refresh token for Microsoft Graph, extract it from the keychain after a successful login. MSAL stores credentials as JSON in the keychain. The following method queries all keychain entries and filters for refresh tokens:

```swift
import Security

func extractMicrosoftGraphRefreshToken() {
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecReturnAttributes as String: true,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll
  ]
  var result: AnyObject?
  let status = withUnsafeMutablePointer(to: &result) {
    SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
  }
  if status == noErr, let array = result as? [[String: Any]] {
    for item in array {
      if let data = item[kSecValueData as String] as? Data,
         let string = String(data: data, encoding: .utf8),
         string.contains("\"credential_type\":\"RefreshToken\"") {
        if let jsonData = string.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
           let refreshToken = json["secret"] as? String {
          print("MICROSOFT_GRAPH_REFRESH_TOKEN=\(refreshToken)")
        }
      }
    }
  }
}
```

#### pCloud

To get the access token for pCloud, extract it from the `PCloudCredential` after a successful login. The credential's `user` property has public access to the token and API host name. The following can be added to `CloudAuthenticator.authenticatePCloud` in the iOS app:

```swift
// Inside the .then block, `credential` is a PCloudCredential
print("PCLOUD_ACCESS_TOKEN=\(credential.user.token)")
print("PCLOUD_HTTP_API_HOST_NAME=\(credential.user.httpAPIHostName)")
```

## Create Integration Tests for New Cloud Provider

To create a new set of integration tests based on `CloudAccessIntegrationTest` for a new `CloudProvider`, the following template can be used:

```swift
#if canImport(CryptomatorCloudAccessCore)
import CryptomatorCloudAccessCore
#else
import CryptomatorCloudAccess
#endif
import XCTest

class CloudProviderNameCloudProviderIntegrationTests: CloudAccessIntegrationTest {
  override class var defaultTestSuite: XCTestSuite {
    return XCTestSuite(forTestCaseClass: CloudProviderNameCloudProviderIntegrationTests.self)
  }

  override class func setUp() {
    // This is the folder in which all the files and folders required by the integration test are created and in which the individual tests are executed. This can also be the root folder.
    integrationTestParentCloudPath = CloudPath("<YOUR-PATH>")
    setUpProvider = CloudProviderNameCloudProvider()
    // It is very important to call super.setUp(), otherwise the IntegrationTest will not be built correctly.
    super.setUp()
  }

  override func setUpWithError() throws {
    // It is very important to call super.setUpWithError(), otherwise errors from the IntegrationTest once setup will not be considered correctly.
    try super.setUpWithError()
    super.provider = CloudProviderNameCloudProvider()
  }
}
```

### Authentication

If the cloud provider requires authentication, subclass `CloudAccessIntegrationTestWithAuthentication` instead of `CloudAccessIntegrationTest`. This extends it by tests for unauthorized `CloudProvider` actions.

The template from above can still be used. Additionally, the following function must be overridden:

```swift
class CloudProviderNameCloudProviderIntegrationTests: CloudAccessIntegrationTestWithAuthentication {
  override func deauthenticate() -> Promise<Void>{
    // Invalidate or deauthenticate the credential or client used by the CloudProvider.
  }
}
```

## Important Notes

The respective `CloudProvider` is tested here very generally for the specifications of the `CloudProvider` protocol. Special characteristics of the cloud provider must be tested separately.

### Dropbox

- Correct use of `batchUpload` (file size >= 150mb).

### Google Drive

- Correct use of the cache for `resolvePath`.

### Microsoft Graph

- Correct use of the cache for `resolvePath`.

### pCloud

- Correct use of the cache for `resolvePath`.

### S3

- Correct use of `multiPartCopy`.
