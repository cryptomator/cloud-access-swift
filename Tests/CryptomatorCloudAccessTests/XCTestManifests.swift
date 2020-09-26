#if !canImport(ObjectiveC)
import XCTest

extension CloudPathTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__CloudPathTests = [
        ("testAppendingPathComponent", testAppendingPathComponent),
        ("testAppendingPathExtension", testAppendingPathExtension),
        ("testDeletingLastPathComponent", testDeletingLastPathComponent),
        ("testDeletingPathExtension", testDeletingPathExtension),
        ("testLastPathComponent", testLastPathComponent),
        ("testPathComponents", testPathComponents),
        ("testPathExtension", testPathExtension),
        ("testStandardizedPath", testStandardizedPath),
        ("testTrimmingLeadingCharacters", testTrimmingLeadingCharacters),
        ("testURLInitWithCloudPathRelativeToBase", testURLInitWithCloudPathRelativeToBase),
    ]
}

extension CloudProvider_ConvenienceTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__CloudProvider_ConvenienceTests = [
        ("testCheckForItemExistenceFulfillsForExistingItem", testCheckForItemExistenceFulfillsForExistingItem),
        ("testCheckForItemExistenceFulfillsForMissingItem", testCheckForItemExistenceFulfillsForMissingItem),
        ("testCheckForItemExistenceRejectsWithErrorOtherThanItemNotFound", testCheckForItemExistenceRejectsWithErrorOtherThanItemNotFound),
        ("testCreateFolderIfMissingFulfillsForExistingItem", testCreateFolderIfMissingFulfillsForExistingItem),
        ("testCreateFolderIfMissingFulfillsForMissingItem", testCreateFolderIfMissingFulfillsForMissingItem),
        ("testCreateFolderIfMissingRejectsWithErrorOtherThanItemNotFound", testCreateFolderIfMissingRejectsWithErrorOtherThanItemNotFound),
        ("testDeleteFolderIfExistingFulfillsForExistingItem", testDeleteFolderIfExistingFulfillsForExistingItem),
        ("testDeleteFolderIfExistingFulfillsForMissingItem", testDeleteFolderIfExistingFulfillsForMissingItem),
        ("testDeleteFolderIfExistingRejectsWithErrorOtherThanItemNotFound", testDeleteFolderIfExistingRejectsWithErrorOtherThanItemNotFound),
        ("testFetchItemListExhaustively", testFetchItemListExhaustively),
    ]
}

extension DirectoryIdCacheTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__DirectoryIdCacheTests = [
        ("testContainsRootPath", testContainsRootPath),
        ("testGetCached", testGetCached),
        ("testInvalidate", testInvalidate),
        ("testRecursiveGet", testRecursiveGet),
    ]
}

extension LocalFileSystemTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__LocalFileSystemTests = [
        ("testCreateFolder", testCreateFolder),
        ("testCreateFolderWithAlreadyExistsError", testCreateFolderWithAlreadyExistsError),
        ("testCreateFolderWithParentFolderDoesNotExistError", testCreateFolderWithParentFolderDoesNotExistError),
        ("testDeleteFile", testDeleteFile),
        ("testDeleteFileWithNotFoundError", testDeleteFileWithNotFoundError),
        ("testDeleteFolder", testDeleteFolder),
        ("testDownloadFile", testDownloadFile),
        ("testDownloadFileWithAlreadyExistsError", testDownloadFileWithAlreadyExistsError),
        ("testDownloadFileWithNotFoundError", testDownloadFileWithNotFoundError),
        ("testDownloadFileWithTypeMismatchError", testDownloadFileWithTypeMismatchError),
        ("testFetchItemList", testFetchItemList),
        ("testFetchItemListWithNotFoundError", testFetchItemListWithNotFoundError),
        ("testFetchItemListWithTypeMismatchError", testFetchItemListWithTypeMismatchError),
        ("testFetchItemMetadata", testFetchItemMetadata),
        ("testFetchItemMetadataWithNotFoundError", testFetchItemMetadataWithNotFoundError),
        ("testMoveFile", testMoveFile),
        ("testMoveFileWithAlreadyExistsError", testMoveFileWithAlreadyExistsError),
        ("testMoveFileWithNotFoundError", testMoveFileWithNotFoundError),
        ("testMoveFileWithParentFolderDoesNotExistError", testMoveFileWithParentFolderDoesNotExistError),
        ("testUploadFile", testUploadFile),
        ("testUploadFileWithAlreadyExistsError", testUploadFileWithAlreadyExistsError),
        ("testUploadFileWithNotFoundError", testUploadFileWithNotFoundError),
        ("testUploadFileWithParentFolderDoesNotExistError", testUploadFileWithParentFolderDoesNotExistError),
        ("testUploadFileWithReplaceExistingAndTypeMismatchError", testUploadFileWithReplaceExistingAndTypeMismatchError),
        ("testUploadFileWithReplaceExistingOnExistingRemoteFile", testUploadFileWithReplaceExistingOnExistingRemoteFile),
        ("testUploadFileWithReplaceExistingOnMissingRemoteFile", testUploadFileWithReplaceExistingOnMissingRemoteFile),
        ("testUploadFileWithTypeMismatchError", testUploadFileWithTypeMismatchError),
    ]
}

extension PropfindResponseParserTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__PropfindResponseParserTests = [
        ("testResponseWith403Status", testResponseWith403Status),
        ("testResponseWithEmptyFolder", testResponseWithEmptyFolder),
        ("testResponseWithFileAndFolder", testResponseWithFileAndFolder),
        ("testResponseWithMalformattedDate", testResponseWithMalformattedDate),
        ("testResponseWithMalformattedXML", testResponseWithMalformattedXML),
        ("testResponseWithMissingHref", testResponseWithMissingHref),
        ("testResponseWithPartial404Status", testResponseWithPartial404Status),
    ]
}

extension VaultFormat6CloudProviderMockTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat6CloudProviderMockTests = [
        ("testDir1FileContainsDirId", testDir1FileContainsDirId),
        ("testVaultRootContainsFiles", testVaultRootContainsFiles),
    ]
}

extension VaultFormat6ProviderDecoratorTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat6ProviderDecoratorTests = [
        ("testCreateFolder", testCreateFolder),
        ("testDeleteFile", testDeleteFile),
        ("testDeleteFolder", testDeleteFolder),
        ("testDownloadFile", testDownloadFile),
        ("testFetchItemListForRootDir", testFetchItemListForRootDir),
        ("testFetchItemListForSubDir", testFetchItemListForSubDir),
        ("testFetchItemMetadata", testFetchItemMetadata),
        ("testMoveFile", testMoveFile),
        ("testUploadFile", testUploadFile),
    ]
}

extension VaultFormat6ShortenedNameCacheTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat6ShortenedNameCacheTests = [
        ("testDeflatePath", testDeflatePath),
        ("testGetCached", testGetCached),
        ("testgetOriginalPath", testgetOriginalPath),
        ("testgetShortenedPath1", testgetShortenedPath1),
        ("testgetShortenedPath2", testgetShortenedPath2),
    ]
}

extension VaultFormat6ShorteningProviderDecoratorTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat6ShorteningProviderDecoratorTests = [
        ("testCreateFolder", testCreateFolder),
        ("testCreateFolderWithLongName", testCreateFolderWithLongName),
        ("testDeleteFile", testDeleteFile),
        ("testDeleteFileWithLongName", testDeleteFileWithLongName),
        ("testDeleteFolder", testDeleteFolder),
        ("testDeleteFolderWithLongName", testDeleteFolderWithLongName),
        ("testDownloadFile", testDownloadFile),
        ("testDownloadFileWithLongName", testDownloadFileWithLongName),
        ("testFetchItemListForRootDir", testFetchItemListForRootDir),
        ("testFetchItemListForSubDir", testFetchItemListForSubDir),
        ("testFetchItemListForSubDirWithLongName", testFetchItemListForSubDirWithLongName),
        ("testFetchItemMetadata", testFetchItemMetadata),
        ("testFetchItemMetadataWithLongName", testFetchItemMetadataWithLongName),
        ("testMoveFile", testMoveFile),
        ("testMoveFileFromLongToLongName", testMoveFileFromLongToLongName),
        ("testMoveFileFromLongToShortName", testMoveFileFromLongToShortName),
        ("testMoveFileFromShortToLongName", testMoveFileFromShortToLongName),
        ("testMoveFolderFromLongToShortName", testMoveFolderFromLongToShortName),
        ("testMoveFolderFromShortToLongName", testMoveFolderFromShortToLongName),
        ("testUploadFile", testUploadFile),
        ("testUploadFileWithLongName", testUploadFileWithLongName),
    ]
}

extension VaultFormat7CloudProviderMockTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat7CloudProviderMockTests = [
        ("testDir1FileContainsDirId", testDir1FileContainsDirId),
        ("testVaultRootContainsFiles", testVaultRootContainsFiles),
    ]
}

extension VaultFormat7ProviderDecoratorTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat7ProviderDecoratorTests = [
        ("testCreateFolder", testCreateFolder),
        ("testDeleteFile", testDeleteFile),
        ("testDeleteFolder", testDeleteFolder),
        ("testDownloadFile", testDownloadFile),
        ("testFetchItemListForRootDir", testFetchItemListForRootDir),
        ("testFetchItemListForSubDir", testFetchItemListForSubDir),
        ("testFetchItemMetadata", testFetchItemMetadata),
        ("testMoveFile", testMoveFile),
        ("testUploadFile", testUploadFile),
    ]
}

extension VaultFormat7ShortenedNameCacheTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat7ShortenedNameCacheTests = [
        ("testDeflatePath1", testDeflatePath1),
        ("testDeflatePath2", testDeflatePath2),
        ("testDeflatePath3", testDeflatePath3),
        ("testGetCached", testGetCached),
        ("testgetOriginalPath1", testgetOriginalPath1),
        ("testgetOriginalPath2", testgetOriginalPath2),
        ("testgetShortenedPath1", testgetShortenedPath1),
        ("testgetShortenedPath2", testgetShortenedPath2),
        ("testgetShortenedPath3", testgetShortenedPath3),
    ]
}

extension VaultFormat7ShorteningProviderDecoratorTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__VaultFormat7ShorteningProviderDecoratorTests = [
        ("testCreateFolder", testCreateFolder),
        ("testCreateFolderWithLongName", testCreateFolderWithLongName),
        ("testDeleteFile", testDeleteFile),
        ("testDeleteFileWithLongName", testDeleteFileWithLongName),
        ("testDeleteFolder", testDeleteFolder),
        ("testDeleteFolderWithLongName", testDeleteFolderWithLongName),
        ("testDownloadFile", testDownloadFile),
        ("testDownloadFileWithLongName", testDownloadFileWithLongName),
        ("testFetchItemListForRootDir", testFetchItemListForRootDir),
        ("testFetchItemListForSubDir", testFetchItemListForSubDir),
        ("testFetchItemListForSubDirWithLongName", testFetchItemListForSubDirWithLongName),
        ("testFetchItemMetadata", testFetchItemMetadata),
        ("testFetchItemMetadataWithLongName", testFetchItemMetadataWithLongName),
        ("testMoveFile", testMoveFile),
        ("testMoveFileFromLongToLongName", testMoveFileFromLongToLongName),
        ("testMoveFileFromLongToShortName", testMoveFileFromLongToShortName),
        ("testMoveFileFromShortToLongName", testMoveFileFromShortToLongName),
        ("testMoveFolderFromLongToShortName", testMoveFolderFromLongToShortName),
        ("testMoveFolderFromShortToLongName", testMoveFolderFromShortToLongName),
        ("testUploadFile", testUploadFile),
        ("testUploadFileWithLongName", testUploadFileWithLongName),
    ]
}

extension WebDAVAuthenticatorTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__WebDAVAuthenticatorTests = [
        ("testVerifyClient", testVerifyClient),
    ]
}

extension WebDAVProviderTests {
    // DO NOT MODIFY: This is autogenerated, use:
    //   `swift test --generate-linuxmain`
    // to regenerate.
    static let __allTests__WebDAVProviderTests = [
        ("testCreateFolder", testCreateFolder),
        ("testCreateFolderWithAlreadyExistsError", testCreateFolderWithAlreadyExistsError),
        ("testCreateFolderWithParentFolderDoesNotExistError", testCreateFolderWithParentFolderDoesNotExistError),
        ("testDeleteFile", testDeleteFile),
        ("testDeleteFileWithNotFoundError", testDeleteFileWithNotFoundError),
        ("testDownloadFile", testDownloadFile),
        ("testDownloadFileWithAlreadyExistsError", testDownloadFileWithAlreadyExistsError),
        ("testDownloadFileWithNotFoundError", testDownloadFileWithNotFoundError),
        ("testDownloadFileWithTypeMismatchError", testDownloadFileWithTypeMismatchError),
        ("testFetchItemList", testFetchItemList),
        ("testFetchItemListWithNotFoundError", testFetchItemListWithNotFoundError),
        ("testFetchItemListWithTypeMismatchError", testFetchItemListWithTypeMismatchError),
        ("testFetchItemMetadata", testFetchItemMetadata),
        ("testFetchItemMetadataWithNotFoundError", testFetchItemMetadataWithNotFoundError),
        ("testMoveFile", testMoveFile),
        ("testMoveFileWithAlreadyExistsError", testMoveFileWithAlreadyExistsError),
        ("testMoveFileWithNotFoundError", testMoveFileWithNotFoundError),
        ("testMoveFileWithParentFolderDoesNotExistError", testMoveFileWithParentFolderDoesNotExistError),
        ("testUploadFile", testUploadFile),
        ("testUploadFileWithAlreadyExistsError", testUploadFileWithAlreadyExistsError),
        ("testUploadFileWithNotFoundError", testUploadFileWithNotFoundError),
        ("testUploadFileWithParentFolderDoesNotExistError", testUploadFileWithParentFolderDoesNotExistError),
        ("testUploadFileWithReplaceExisting", testUploadFileWithReplaceExisting),
        ("testUploadFileWithReplaceExistingAndTypeMismatchError", testUploadFileWithReplaceExistingAndTypeMismatchError),
        ("testUploadFileWithTypeMismatchError", testUploadFileWithTypeMismatchError),
    ]
}

public func __allTests() -> [XCTestCaseEntry] {
    return [
        testCase(CloudPathTests.__allTests__CloudPathTests),
        testCase(CloudProvider_ConvenienceTests.__allTests__CloudProvider_ConvenienceTests),
        testCase(DirectoryIdCacheTests.__allTests__DirectoryIdCacheTests),
        testCase(LocalFileSystemTests.__allTests__LocalFileSystemTests),
        testCase(PropfindResponseParserTests.__allTests__PropfindResponseParserTests),
        testCase(VaultFormat6CloudProviderMockTests.__allTests__VaultFormat6CloudProviderMockTests),
        testCase(VaultFormat6ProviderDecoratorTests.__allTests__VaultFormat6ProviderDecoratorTests),
        testCase(VaultFormat6ShortenedNameCacheTests.__allTests__VaultFormat6ShortenedNameCacheTests),
        testCase(VaultFormat6ShorteningProviderDecoratorTests.__allTests__VaultFormat6ShorteningProviderDecoratorTests),
        testCase(VaultFormat7CloudProviderMockTests.__allTests__VaultFormat7CloudProviderMockTests),
        testCase(VaultFormat7ProviderDecoratorTests.__allTests__VaultFormat7ProviderDecoratorTests),
        testCase(VaultFormat7ShortenedNameCacheTests.__allTests__VaultFormat7ShortenedNameCacheTests),
        testCase(VaultFormat7ShorteningProviderDecoratorTests.__allTests__VaultFormat7ShorteningProviderDecoratorTests),
        testCase(WebDAVAuthenticatorTests.__allTests__WebDAVAuthenticatorTests),
        testCase(WebDAVProviderTests.__allTests__WebDAVProviderTests),
    ]
}
#endif
