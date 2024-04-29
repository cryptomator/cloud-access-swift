# Integration Tests

Test the individual `CloudProvider` implementations against the live API of the respective cloud.

## Secrets

If you would like to run integration tests that require authentication, you have to set some secrets for them. Create a `.integration-test-secrets.sh` file in the root directory. Its contents should look something like this:

```sh
#!/bin/sh
export BOX_DEVELOPER_TOKEN=...
export DROPBOX_ACCESS_TOKEN=...
export GOOGLE_DRIVE_CLIENT_ID=...
export GOOGLE_DRIVE_REFRESH_TOKEN=...
export ONEDRIVE_CLIENT_ID=...
export ONEDRIVE_REDIRECT_URI_SCHEME=...
export ONEDRIVE_REFRESH_TOKEN=...
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

#### Box

To get a developer token for Box, generate it in the Box Developer Portal, keeping in mind that it expires after 60 minutes. For more detailed instructions, check out the [OAuth 2.0 Documentation from Box](https://developer.box.com/guides/authentication/oauth2/).

To obtain the refresh token from Box, it is recommended to extract it from `authenticate` after a successful login. The easiest way to do this is to set a breakpoint inside the `BoxAuthenticator`:

```swift
public static func authenticate(from viewController: UIViewController, tokenStore: TokenStore) -> Promise<(BoxClient, String)> {
	return Promise {
  // ...
  fulfill((client, user.id)) // set breakpoint here
  // ...
}
```

#### Dropbox

To get the access token for Dropbox, generate a token in the Dropbox Developer Portal. For more detailed instructions, check out the [OAuth Guide from Dropbox](https://developers.dropbox.com/oauth-guide).

#### Google Drive

To get the refresh token for Google Drive, it is recommended to extract it from the `authState` after a successful login. The easiest way to do this is to set a breakpoint inside the `GoogleDriveAuthenticator`:

```swift
private static func getAuthState(for configuration: OIDServiceConfiguration, with presentingViewController: UIViewController, credential: GoogleDriveCredential) -> Promise<OIDAuthState> {
  // ...
  fulfill(authState) // set breakpoint here
  // ...
}
```

#### OneDrive

To get the secrets for OneDrive, it is necessary to extract them from the keychain after a successful login. The following method may help you to extract the OneDrive secrets from the keychain:

```swift
func extractOneDriveSecretsFromKeychain() {
  let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecReturnAttributes as String: true,
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitAll
  ]
  var result: AnyObject?
  let lastResultCode = withUnsafeMutablePointer(to: &result) {
    SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
  }
  if lastResultCode == noErr {
    guard let array = result as? [[String: Any]] else {
      print("No items were found in the keychain")
      return
    }
    for item in array {
      if let data = item[kSecValueData as String] as? Data, let string = String(data: data, encoding: .utf8) {
        if string.contains("\"credential_type\":\"RefreshToken\"") {
          print("OneDrive Refresh Token Data:\n\(string)")
        }
      }
    }
  }
}
```

#### pCloud

To get the access token for pCloud, it is recommended to extract it from `completeAuthorizationFlow` after a successful login. The easiest way to do this is to set a breakpoint inside the `PCloudAuthenticator`:

```swift
private func completeAuthorizationFlow(result: OAuth.Result) throws -> PCloudCredential {
  // ...
  return PCloudCredential(user: user) // set breakpoint here
  // ...
}
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

### OneDrive

- Correct use of the cache for `resolvePath`.

### pCloud

- Correct use of the cache for `resolvePath`.

### S3

- Correct use of `multiPartCopy`.