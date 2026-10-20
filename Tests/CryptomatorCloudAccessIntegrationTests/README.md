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

#### Box

The Box tests authenticate as the service account of a Box Platform app that uses the client credentials grant (CCG), so they need no stored login. Take `BOX_CLIENT_ID` and `BOX_CLIENT_SECRET` from the app's configuration in the Box Developer Console, and set `BOX_ENTERPRISE_ID` to the ID of the enterprise whose admin authorized the app.

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

To get the access token and API host name for pCloud, read them from the `PCloudCredential` after a successful login. The following can be added to `CloudAuthenticator.authenticatePCloud` in the iOS app:

```swift
// After `try await PCloudAuthenticator.authenticate(from:)` returns, `credential` is a PCloudCredential
print("PCLOUD_ACCESS_TOKEN=\(credential.accessToken)")
print("PCLOUD_HTTP_API_HOST_NAME=\(credential.apiHostName)")
```

## Running the Tests

The tests are Swift Testing suites that run in parallel in one process, so the tests of a provider share its credentials and fixtures. A backend is a provider combined with a vault format (`plain`, `vf6`, `vf7`) and is named by a token like `pcloud-vf7`. The conformance tests in `CloudProviderConformanceTests.swift` run once per selected backend.

`INTEGRATION_BACKENDS` selects the backends: comma-separated provider tokens (`pcloud`) or backend tokens (`pcloud-vf7`). Unset or empty selects all backends, and `none` selects none, so only the tests that don't depend on the selection run. An unknown token fails `backendSelectionIsValid`, so a typo can't pass a run that tested nothing. The provider tokens are `box`, `dropbox`, `googledrive`, `microsoftgraph`, `pcloud`, `s3`, `webdav` and `localfilesystem`. Each per-provider scheme, e.g. `PCloudIntegrationTests`, sets the filter to its provider. `AllIntegrationTests` sets none. To filter it, set `TEST_RUNNER_INTEGRATION_BACKENDS` in the environment of `xcodebuild`.

To run the tests like CI does, build with `xcodebuild build-for-testing -scheme AllIntegrationTests -destination 'name=<simulator>'` and then run `DEVICE='<simulator>' BACKENDS=pcloud ./Scripts/run-integration-tests.sh`.

## Writing Tests

A conformance test takes `IntegrationBackend.selected` as its arguments, or a subset (`selectedPlain`, `selectedPlainRemote`, `selectedPaginating`, `selectedVaults`) if it only applies to some backends. Each test of a backend runs its body through `withIntegrationFixture(_:_:)`, which hands each attempt a new `IntegrationTestContext` with the backend's provider:

- The read-only tree at `context.treeRoot` (`test 0…4.txt` and `testFolder` with `EmptySubfolder` and `test 0…4.txt`) is built once per backend and read by all of its tests in parallel, so it must not be changed.
- A test that changes anything works in a folder of its own from `context.makeSandbox()` and creates its items with `createPrerequisiteFolder(at:)` and `uploadPrerequisite(_:to:)`, which wait until the item is visible. `sandboxPath()` returns a unique path without creating anything.
- Remote calls come before the expectations, because a retried test keeps the issues it recorded. For the same reason, expected errors go through `expectCloudProviderError(_:sourceLocation:_:)`, which rethrows a transient error instead of recording it. Use `eventually(on:_:)` to wait out the visibility lag after a change.

A provider-specific suite is nested in `IntegrationTests.ProviderSpecific`, so it runs within the sweep and cleanup of the run. It is gated with `.enabled(if: IntegrationBackend.isSelected(.<provider>))`. Its name is the provider token followed by `Tests`, in any case, e.g. `S3Tests` or `GoogleDriveTests`, because the CI script re-runs a failed test with the provider whose token it derives from the name. A test that needs no fixture runs its body through `withIntegrationRetries(on:_:)`, which retries and bounds it the same way.

To add a provider, add a case to `IntegrationProvider`, create its providers in `IntegrationProvider+Factory.swift` and add a scheme that sets `INTEGRATION_BACKENDS` to its token.

## Retries

An attempt that fails with a transient error is retried in-process with a new context, at most twice. Transient errors are connection losses and timeouts, `CloudProviderError.noInternetConnection`, HTTP 5xx and 429, failed OAuth token requests with such a status, and eventually consistent providers that didn't catch up in time. Each retry is logged as `[integration-retry]`. Any other error fails the test without a retry.

An attempt runs while it holds one of its provider's few permits (`IntegrationProvider.concurrencyLimit`), so the account isn't overloaded. It fails once it has held the permit for 5 minutes, and it is left running, because a running request doesn't respond to cancellation.

In CI, `Scripts/run-integration-tests.sh` re-runs the failed tests once against the same build. It runs every failed test on every backend that a test failed on, so a test can also run on a backend it didn't fail on. A failed provider-specific test adds all backends of its provider. The job is green only if each failed (test, backend) pair passed on the re-run, so the extra runs don't count. A re-run of the job via "Re-run failed jobs" selects the same way from the pairs still failing at the end of the previous attempt, and its main pass then counts all the pairs it runs. If that attempt didn't finish its main pass, it runs everything.

The script's summary lists the pairs that passed only on the re-run, those still failing, the in-process retries, and why a pass didn't complete. It goes to the log as well as the job summary, because the job summary can't be read through the API. Both are public, and a failure message can contain request URLs with credentials, e.g., in the user info of a `URLError`. So the summary shows only the parts of a failure message that can't contain them, such as an error's domain and code. It also names the file and line of the failing check.

## Remote Folders

Each run works in `/iOS-IntegrationTests-<timestamp>-<runID>` on each provider and deletes it at the end. A root of its own per run avoids the eventual consistency races on S3 and pCloud, where deleting a path and immediately recreating it can fail. A run that is killed can't delete its root, so each run starts by deleting such folders that are older than 24 hours. Folders named `iOS-IntegrationTests-{Plain|VaultFormat6|VaultFormat7}-<runID>` can belong to a running build of an older release, so they are only deleted when empty or when their newest file is older than 24 hours.

## Important Notes

The respective `CloudProvider` is tested here very generally for the specifications of the `CloudProvider` protocol. Special characteristics of the cloud provider must be tested separately.

### Dropbox

- Correct use of the upload session (file size >= 150 MiB).

### Google Drive

- Correct use of the cache for `resolvePath`.

### Microsoft Graph

- Correct use of the cache for `resolvePath`.

### pCloud

- Correct use of the cache for `resolvePath`.

### S3

- Correct use of `multiPartCopy`.
