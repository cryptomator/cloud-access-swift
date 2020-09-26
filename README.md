[![Version](http://img.shields.io/cocoapods/v/CryptomatorCloudAccess.svg)](https://cocoapods.org/pods/CryptomatorCloudAccess)
[![Codacy Badge](https://app.codacy.com/project/badge/Grade/35951085e6604f9aaab998fc65dd2467)](https://www.codacy.com/gh/cryptomator/cloud-access-swift)
[![Codacy Badge](https://app.codacy.com/project/badge/Coverage/35951085e6604f9aaab998fc65dd2467)](https://www.codacy.com/gh/cryptomator/cloud-access-swift)

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
`pod 'CryptomatorCloudAccess', '~> 1.0.0'`
```

## Contributing to Cloud Access Swift

Please read our [contribution guide](.github/CONTRIBUTING.md), if you would like to report a bug, ask a question or help us with coding.

## Code of Conduct

Help us keep Cryptomator open and inclusive. Please read and follow our [Code of Conduct](.github/CODE_OF_CONDUCT.md).

## License

Distributed under the AGPLv3. See the LICENSE file for more info.
