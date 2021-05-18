# Integration Tests

Test the individual `CloudProvider` implementations against the live API of the respective cloud.

## Secrets

If you would like to run integration tests that require authentication, you have to set some secrets for them. Create a `.integration-test-secrets.sh` file in the root directory. Its contents should look something like this:

```sh
#!/bin/sh
export DROPBOX_ACCESS_TOKEN=...
export GOOGLE_DRIVE_CLIENT_ID=...
export GOOGLE_DRIVE_REFRESH_TOKEN=...
export ONEDRIVE_CLIENT_ID=...
export ONEDRIVE_REDIRECT_URI_SCHEME=...
export ONEDRIVE_REFRESH_TOKEN_DATA=...
export ONEDRIVE_ACCOUNT_DATA=...
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
        if string.hasPrefix("{\"client_id\":") && string.contains("\"credential_type\":\"RefreshToken\"") {
          print("OneDrive Refresh Token Data:\n\(string)")
        } else if string.hasPrefix("{\"client_info\":") {
          print("OneDrive Account Data:\n\(string)")
        }
      }
    }
  }
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
  static var setUpErrorForCloudProviderName: Error?

  override class var classSetUpError: Error? {
    get {
      return setUpErrorForCloudProviderName
    }
    set {
      setUpErrorForCloudProviderName = newValue
    }
  }

  static let setUpProviderForCloudProviderName = CloudProviderNameCloudProvider()
  
  override class var setUpProvider: CloudProvider {
    return setUpProviderForCloudProviderName
  }

  // This is the folder in which all the files and folders required by the integration test are created and in which the individual tests are executed. This can also be the root folder.
  
  override class var integrationTestParentCloudPath: CloudPath {
    return CloudPath("<YOUR-PATH>")
  }

  // If you do not need to initialize anything special once or before the IntegrationTest setup, you can ignore this function.
  override class func setUp() {
    // It is very important to call super.setUp(), otherwise the IntegrationTest will not be built correctly.
    super.setUp()
  }

  override func setUpWithError() throws {
    // It is very important to call super.setUpWithError(), otherwise errors from the IntegrationTest once setup will not be considered correctly.
    try super.setUpWithError()
    super.provider = CloudProviderNameCloudProvider()
  }

  override class var defaultTestSuite: XCTestSuite {
    return XCTestSuite(forTestCaseClass: CloudProviderNameCloudProviderIntegrationTests.self)
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
