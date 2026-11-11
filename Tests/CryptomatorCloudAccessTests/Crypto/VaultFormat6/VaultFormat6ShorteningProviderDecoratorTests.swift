//
//  VaultFormat6ShorteningProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import XCTest
#if canImport(CryptomatorCloudAccessCore)
@testable import CryptomatorCloudAccessCore
#else
@testable import CryptomatorCloudAccess
#endif

class VaultFormat6ShorteningProviderDecoratorTests: VaultFormat6ProviderDecoratorTests {
	var shorteningDecorator: VaultFormat6ShorteningProviderDecorator!

	override func setUpWithError() throws {
		try super.setUpWithError()
		shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		decorator = try VaultFormat6ProviderDecorator(delegate: shorteningDecorator, vaultPath: vaultPath, cryptor: cryptor)
	}

	override func tearDownWithError() throws {
		shorteningDecorator = nil
		try super.tearDownWithError()
	}

	private let legacyDirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
	/// A name of 129 characters, which old Cryptomator versions shortened and current ones keep.
	private let legacyOriginalName = "0" + String(repeating: "A", count: 128)
	private let legacyShortenedName = "TZWGC22CUSVOSQATCBD3274ZQV7ZI53A.lng"

	private func makeProviderWithLegacyShortenedName(files: [String: Data] = [:]) -> CloudProviderMock {
		let legacyFiles = [
			"\(legacyDirPath)/\(legacyShortenedName)": Data(),
			"pathToVault/m/TZ/WG/\(legacyShortenedName)": Data(legacyOriginalName.utf8)
		]
		return CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", legacyDirPath], files: legacyFiles.merging(files) { $1 })
	}

	override func testFetchItemListForRootDir() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)
		XCTAssertEqual(6, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 3 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 1" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 2" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 4 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 5 (Long)" }))
	}

	func testFetchItemMetadataWithLongName() async throws {
		let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
		XCTAssertEqual("File 6 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/Directory 3 (Long)/File 6 (Long)", metadata.cloudPath.path)
	}

	func testFetchItemListForSubDirWithLongName() async throws {
		let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 3 (Long)"), withPageToken: nil)
		XCTAssertEqual(2, itemList.items.count)
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "File 6 (Long)" }))
		XCTAssertTrue(itemList.items.contains(where: { $0.name == "Directory 4 (Long)" }))
	}

	func testFetchItemListWithCancelledNameLookup() async throws {
		provider.transferHook = { cloudPath, _ in
			if cloudPath.path == "pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng" {
				throw CancellationError()
			}
		}
		await XCTAssertThrowsErrorAsync(try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil)) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	/// The name files of these names would lie in other directories than `m/<2 characters>/<2 characters>`, where the mock holds them.
	func testFetchItemListSkipsNamesThatAreNoDeflatedNames() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
			"\(dirPath)/..AB.lng": Data(),
			"\(dirPath)/....lng": Data(),
			"\(dirPath)/AB...lng": Data(),
			"\(dirPath)/file1": Data(),
			"pathToVault/AB/..AB.lng": Data("outsideM".utf8),
			"....lng": Data("outsideVault".utf8),
			"pathToVault/m/AB...lng": Data("wrongLevel".utf8)
		])
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertEqual(["\(dirPath)/file1"], itemList.items.map(\.cloudPath.path))
		XCTAssertFalse(provider.calls.contains("downloadFile"))
		XCTAssertTrue(provider.moved.isEmpty)
	}

	func testFetchItemListWithOnlyInvalidNamesIsEmpty() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
			"\(dirPath)/..AB.lng": Data(),
			"\(dirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data(),
			"pathToVault/m/4H/GU/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data("..".utf8)
		])
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertTrue(itemList.items.isEmpty)
	}

	/// The swapped name files hold valid names, so only the comparison with the listed name leaves their items out.
	func testFetchItemListSkipsNamesWhoseNameFileBelongsToAnotherName() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let longName = String(repeating: "a", count: 130)
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
			"\(dirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data(),
			"\(dirPath)/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": Data(),
			"\(dirPath)/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": Data(),
			"pathToVault/m/4H/GU/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data(longName.utf8),
			"pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng": Data(String(repeating: "file5", count: 26).utf8),
			"pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng": Data(String(repeating: "file4", count: 26).utf8)
		])
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
		XCTAssertEqual(["\(dirPath)/\(longName)"], itemList.items.map(\.cloudPath.path))
		XCTAssertTrue(provider.moved.isEmpty)
	}

	func testFetchItemListMovesLegacyShortenedNameToOriginalName() async throws {
		let provider = makeProviderWithLegacyShortenedName()
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)
		XCTAssertEqual(["\(legacyDirPath)/\(legacyShortenedName)": "\(legacyDirPath)/\(legacyOriginalName)"], provider.moved)
		XCTAssertEqual([legacyOriginalName], itemList.items.map(\.name))
		XCTAssertEqual(["\(legacyDirPath)/\(legacyOriginalName)"], itemList.items.map(\.cloudPath.path))
		XCTAssertEqual([.file], itemList.items.map(\.itemType))
	}

	/// The legacy name is the only item, so the listing would throw if a failed move counted as a failed item.
	func testFetchItemListLeavesOutLegacyShortenedNameThatCannotBeMoved() async throws {
		for error in [CloudProviderError.itemAlreadyExists, .unauthorized, .itemNotFound] {
			let provider = makeProviderWithLegacyShortenedName()
			provider.moveHook = { throw error }
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)
			XCTAssertTrue(itemList.items.isEmpty, "\(error)")
		}
	}

	/// A missing internet connection says nothing about whether the item can be moved, so it counts like a name file that couldn't be downloaded.
	func testFetchItemListWithLegacyShortenedNameThrowsIfMoveFailsWithoutInternetConnection() async throws {
		let provider = makeProviderWithLegacyShortenedName()
		provider.moveHook = { throw CloudProviderError.noInternetConnection }
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)) { error in
			XCTAssertEqual(CloudProviderError.noInternetConnection, error as? CloudProviderError)
		}
	}

	/// The legacy name is listed last, so the listing throws the lookup's error only if the failed move is skipped.
	func testFetchItemListWithUnmovedLegacyShortenedNameAndFailedNameLookupThrows() async throws {
		let provider = makeProviderWithLegacyShortenedName(files: ["\(legacyDirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data()])
		provider.moveHook = { throw CloudProviderError.unauthorized }
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	/**
	 A provider that checks the source first reports the moved item as `itemNotFound`, one that checks the target first as `itemAlreadyExists`.

	 The test seeds the name that the item was moved to. Because the mock's files don't change, the page holds both names, like a page listed during a move that copies and then deletes. The metadata hook reports the shortened name as gone, because the mock's files don't show the move. The listing returns the item once.
	 */
	func testFetchItemListReturnsLegacyShortenedNameThatAnotherListingMoved() async throws {
		let shortenedPath = CloudPath("\(legacyDirPath)/\(legacyShortenedName)")
		for error in [CloudProviderError.itemNotFound, .itemAlreadyExists] {
			let provider = makeProviderWithLegacyShortenedName(files: ["\(legacyDirPath)/\(legacyOriginalName)": Data()])
			provider.moveHook = { throw error }
			provider.metadataHook = { cloudPath in
				if cloudPath == shortenedPath {
					throw CloudProviderError.itemNotFound
				}
			}
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)
			XCTAssertEqual(["\(legacyDirPath)/\(legacyOriginalName)"], itemList.items.map(\.cloudPath.path), "\(error)")
		}
	}

	func testFetchItemListWithCancelledMoveOfLegacyShortenedName() async throws {
		try await assertFetchItemListOfLegacyShortenedNameThrowsCancellationError { $0.moveHook = { throw CancellationError() } }
	}

	func testFetchItemListWithCancelledLookupOfMovedLegacyShortenedName() async throws {
		try await assertFetchItemListOfLegacyShortenedNameThrowsCancellationError { provider in
			provider.moveHook = { throw CloudProviderError.itemNotFound }
			provider.metadataHook = { _ in throw CancellationError() }
		}
	}

	private func assertFetchItemListOfLegacyShortenedNameThrowsCancellationError(_ configure: (CloudProviderMock) -> Void) async throws {
		let provider = makeProviderWithLegacyShortenedName()
		configure(provider)
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)) { error in
			XCTAssertTrue(error is CancellationError)
		}
	}

	/// The invalid name is listed last, so the listing throws the lookup's error only if `invalidNameFile` is skipped.
	func testFetchItemListWithInvalidNamesAndFailedNameLookupThrows() async throws {
		let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
			"\(dirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data(),
			"\(dirPath)/AB...lng": Data()
		])
		let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
		await XCTAssertThrowsErrorAsync(try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)) { error in
			XCTAssertEqual(CloudProviderError.itemNotFound, error as? CloudProviderError)
		}
	}

	func testDownloadFileWithLongName() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		let metadata = try await decorator.downloadFile(from: CloudPath("/File 4 (Long)"), to: localURL)
		let cleartext = try String(contentsOf: localURL, encoding: .utf8)
		XCTAssertEqual("cleartext4", cleartext)
		XCTAssertEqual("File 4 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
		XCTAssertEqual(provider.lastModifiedDate, metadata.lastModifiedDate)
		XCTAssertEqual(10, metadata.size)
	}

	func testUploadFileWithLongName() async throws {
		let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
		try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
		let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q/OD"))
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertEqual(Data("ciphertext4".utf8), provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		XCTAssertEqual(String(repeating: "file4", count: 26).data(using: .utf8), provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		XCTAssertEqual("File 4 (Long)", metadata.name)
		XCTAssertEqual(.file, metadata.itemType)
		XCTAssertEqual("/File 4 (Long)", metadata.cloudPath.path)
		XCTAssertEqual(provider.lastModifiedDate, metadata.lastModifiedDate)
		XCTAssertEqual(0, metadata.size) // CryptorMock calculates a cleartext size of 0
	}

	func testCreateFolderWithLongName() async throws {
		try await decorator.createFolder(at: CloudPath("/Directory 3 (Long)"))
		XCTAssertEqual(5, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL/2X"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
		XCTAssertEqual(2, provider.createdFiles.count)
		XCTAssertNotNil(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
		XCTAssertEqual(Data("0\(String(repeating: "dir3", count: 33))".utf8), provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
	}

	func testDeleteFileWithLongName() async throws {
		try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
		XCTAssertEqual(1, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng"))
	}

	func testDeleteFolderWithLongName() async throws {
		try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)"))
		XCTAssertEqual(3, provider.deleted.count)
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
		XCTAssertTrue(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"))
	}

	func testMoveFileFromShortToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 4 (Long)"))
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/2Q/OD"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(String(repeating: "file4", count: 26).data(using: .utf8), provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"])
	}

	func testMoveFileFromLongToShortName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
	}

	func testMoveFileFromLongToLongName() async throws {
		try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/CI"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/CI/VV"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(String(repeating: "file5", count: 26).data(using: .utf8), provider.createdFiles["pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
	}

	func testMoveFolderFromShortToLongName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)"))
		XCTAssertEqual(3, provider.createdFolders.count)
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL"))
		XCTAssertTrue(provider.createdFolders.contains("pathToVault/m/DL/2X"))
		XCTAssertEqual(1, provider.createdFiles.count)
		XCTAssertEqual(Data("0\(String(repeating: "dir3", count: 33))".utf8), provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"])
	}

	func testMoveFolderFromLongToShortName() async throws {
		try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))
		XCTAssertEqual(1, provider.moved.count)
		XCTAssertEqual("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1", provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
	}

	func testShorteningDecoratorThrowsCancellationErrorInCancelledTask() async {
		await assertThrowsCancellationErrorInCancelledTask(shorteningDecorator)
		XCTAssertEqual([], provider.calls)
	}
}
