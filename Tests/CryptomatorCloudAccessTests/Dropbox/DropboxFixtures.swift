//
//  DropboxFixtures.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

/// Data that the Dropbox SDKs produced, which the library must still read.
enum DropboxFixtures {
	/// Archived by the ObjC Dropbox SDK 7.2.0 from `DBAccessToken(accessToken: "sl.short-lived-access-token", uid: "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc", refreshToken: "refresh-token", tokenExpirationTimestamp: 1_760_000_000)`
	static let objCShortLivedArchive = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGmCwwXGBkaVSRudWxs1Q0ODxAREhMUFRZccmVmcmVzaFRva2VuU3VpZFthY2Nlc3NUb2tlbl8QGHRva2VuRXhwaXJhdGlvblRpbWVzdGFtcFYkY2xhc3OABIACgAMjQdo53gAAAACABV8QKGRiaWQ6QUFINGY5OVQwdGFPTkliLU91cld4Yk5RNnl3R1JvcFFuZ2NfEBtzbC5zaG9ydC1saXZlZC1hY2Nlc3MtdG9rZW5dcmVmcmVzaC10b2tlbtIbHB0eWiRjbGFzc25hbWVYJGNsYXNzZXNdREJBY2Nlc3NUb2tlbqIfIF1EQkFjY2Vzc1Rva2VuWE5TT2JqZWN0AAgAEQAaACQAKQAyADcASQBMAFEAUwBaAGAAawB4AHwAiACjAKoArACuALAAuQC7AOYBBAESARcBIgErATkBPAFKAAAAAAAAAgEAAAAAAAAAIQAAAAAAAAAAAAAAAAAAAVM=")!
	/// Archived by the ObjC Dropbox SDK 7.2.0 from `DBAccessToken(accessToken: "long-lived-access-token", uid: "12345")`
	static let objCLongLivedArchive = Data(base64Encoded: "YnBsaXN0MDDUAQIDBAUGBwpYJHZlcnNpb25ZJGFyY2hpdmVyVCR0b3BYJG9iamVjdHMSAAGGoF8QD05TS2V5ZWRBcmNoaXZlctEICVRyb290gAGlCwwXGBlVJG51bGzVDQ4PEBESExQVFlxyZWZyZXNoVG9rZW5TdWlkW2FjY2Vzc1Rva2VuXxAYdG9rZW5FeHBpcmF0aW9uVGltZXN0YW1wViRjbGFzc4AAgAKAAyMAAAAAAAAAAIAEVTEyMzQ1XxAXbG9uZy1saXZlZC1hY2Nlc3MtdG9rZW7SGhscHVokY2xhc3NuYW1lWCRjbGFzc2VzXURCQWNjZXNzVG9rZW6iHh9dREJBY2Nlc3NUb2tlblhOU09iamVjdAAIABEAGgAkACkAMgA3AEkATABRAFMAWQBfAGoAdwB7AIcAogCpAKsArQCvALgAugDAANoA3wDqAPMBAQEEARIAAAAAAAACAQAAAAAAAAAgAAAAAAAAAAAAAAAAAAABGw==")!

	/// Encoded by SwiftyDropbox 10.2.4 from `DropboxAccessToken(accessToken: "sl.short-lived-access-token", uid: "dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc", refreshToken: "refresh-token", tokenExpirationTimestamp: 1_760_000_000)`
	static let swiftyDropboxShortLived = Data(#"{"uid":"dbid:AAH4f99T0taONIb-OurWxbNQ6ywGRopQngc","tokenExpirationTimestamp":1760000000,"accessToken":"sl.short-lived-access-token","refreshToken":"refresh-token"}"#.utf8)
	/// Encoded by SwiftyDropbox 10.2.4 from `DropboxAccessToken(accessToken: "long-lived-access-token", uid: "12345")`
	static let swiftyDropboxLongLived = Data(#"{"accessToken":"long-lived-access-token","uid":"12345"}"#.utf8)

	/// `server_modified` strings with the `timeIntervalSinceReferenceDate.bitPattern` of the date that SwiftyDropbox 10.2.4's `Files.FileMetadataSerializer` read from them.
	static let serverModifiedDates: [(String, UInt64)] = [
		("2024-02-29T12:00:00Z", 4_739_414_448_664_477_696),
		("1969-12-31T23:59:59Z", 13_964_861_880_833_933_312),
		("9999-12-31T23:59:59Z", 4_777_583_434_807_607_296),
		("1970-01-01T00:00:00Z", 13_964_861_880_825_544_704),
		("2000-01-01T00:00:00Z", 13_942_625_820_448_129_024),
		("2181-03-23T16:48:08Z", 4_752_757_615_988_047_872),
		("2015-09-11T07:04:35Z", 4_736_558_329_285_836_800),
		("2139-07-13T22:59:05Z", 4_751_377_938_124_898_304),
		("2118-04-20T02:25:20Z", 4_750_053_136_377_315_328),
		("2024-10-08T13:57:10Z", 4_739_575_407_848_718_336),
		("2102-06-20T12:00:06Z", 4_749_005_364_186_316_800),
		("2136-09-16T17:19:47Z", 4_751_271_596_929_318_912),
		("1977-09-30T05:17:07Z", 13_962_811_330_671_935_488),
		("2137-06-13T13:32:59Z", 4_751_309_048_814_501_888),
		("1995-07-18T05:24:06Z", 13_953_428_204_698_992_640),
		("2109-04-27T08:51:22Z", 4_749_458_868_851_965_952),
		("2177-10-28T19:56:16Z", 4_752_645_106_392_104_960),
		("2148-05-29T01:21:32Z", 4_751_671_662_452_146_176),
		("2090-07-08T07:58:39Z", 4_748_214_603_482_136_576),
		("1982-08-03T02:15:16Z", 13_961_530_018_707_275_776),
		("2106-10-26T01:21:03Z", 4_749_293_200_934_436_864),
		("2045-03-13T04:48:01Z", 4_743_636_545_402_044_416),
		("2025-10-01T10:32:42Z", 4_739_834_774_649_044_992),
		("2119-04-03T08:53:06Z", 4_750_116_240_658_268_160),
		("2194-05-07T07:27:59Z", 4_753_191_812_006_412_288),
		("2075-03-28T17:54:43Z", 4_747_203_435_145_723_904),
		("2020-05-01T21:42:45Z", 4_738_400_780_724_207_616),
		("2158-04-25T13:34:07Z", 4_751_999_488_366_739_456),
		("2072-12-19T05:51:45Z", 4_747_053_134_405_173_248),
		("2048-08-27T12:31:50Z", 4_744_094_357_999_583_232),
		("2138-11-11T06:43:04Z", 4_751_355_771_059_437_568),
		("2062-06-17T20:02:46Z", 4_745_921_631_099_027_456),
		("2026-11-28T02:41:48Z", 4_740_141_117_771_612_160),
		("2197-09-03T04:30:11Z", 4_753_301_876_134_379_520),
		("2158-03-04T05:40:48Z", 4_751_994_747_545_976_832),
		("2186-03-23T14:12:02Z", 4_752_923_036_227_731_456),
		("2153-02-07T01:56:48Z", 4_751_827_038_468_308_992),
		("2128-03-24T05:29:40Z", 4_750_710_168_772_149_248),
		("2004-03-21T19:21:04Z", 4_726_589_976_429_461_504),
		("2063-06-09T14:18:09Z", 4_746_050_916_841_422_848)
	]

	/// `server_modified` strings that SwiftyDropbox 10.2.4 failed to deserialize.
	static let unparseableServerModifiedDates = ["2026-10-21T08:15:38.5Z", "2026-10-21T08:15:38+01:00"]
}
