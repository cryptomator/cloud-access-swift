//
//  VaultFormat6ShorteningProviderDecoratorTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 21.09.20.
//  Copyright © 2020 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	final class VaultFormat6ShorteningProviderDecoratorTests {
		let vaultPath: CloudPath
		let cryptor: VaultFormat6CryptorMock
		let tmpDirURL: URL
		let provider: VaultFormat6CloudProviderMock
		let shorteningDecorator: VaultFormat6ShorteningProviderDecorator
		let decorator: VaultFormat6ProviderDecorator

		init() throws {
			let vaultPath = CloudPath("pathToVault")
			let cryptor = VaultFormat6CryptorMock()
			let tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
			let fixture = try VaultFormat6Fixture(stacking: .shortening, vaultPath: vaultPath, cryptor: cryptor)
			self.vaultPath = vaultPath
			self.cryptor = cryptor
			self.tmpDirURL = tmpDirURL
			self.provider = fixture.provider
			self.shorteningDecorator = try #require(fixture.shorteningDecorator)
			self.decorator = fixture.decorator
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		private let legacyDirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
		/// A name of 129 characters, which old Cryptomator versions shortened and current ones keep.
		private let legacyOriginalName = "0" + String(repeating: "A", count: 128)
		private let legacyShortenedName = "TZWGC22CUSVOSQATCBD3274ZQV7ZI53A.lng"
		/// A legacy name whose spelling with U+212A KELVIN SIGN for its last `K` equals it as a `String` and shortens to the same name, because the name is hashed in NFC. Cryptolib can't decrypt that spelling.
		private let legacyOriginalNameWithK = "0" + String(repeating: "K", count: 128)
		private let legacyOriginalNameWithKelvinSign = "0" + String(repeating: "K", count: 127) + "\u{212A}"
		private let legacyShortenedNameWithK = "GZFZP46N7NNDDAFEEDBD52V5HV4UQVDA.lng"
		private var legacyFolders: Set<String> {
			["pathToVault", "pathToVault/d", "pathToVault/d/00", legacyDirPath]
		}

		private func makeProviderWithLegacyShortenedName(files: [String: Data] = [:], maxPageSize: Int = .max) -> CloudProviderMock {
			return CloudProviderMock(folders: legacyFolders, files: legacyFiles(legacyShortenedName, nameFileContent: legacyOriginalName).merging(files) { $1 }, maxPageSize: maxPageSize)
		}

		private func legacyFiles(_ shortenedName: String, nameFileContent: String) -> [String: Data] {
			let prefix = shortenedName.prefix(4)
			return [
				"\(legacyDirPath)/\(shortenedName)": Data(),
				"pathToVault/m/\(prefix.prefix(2))/\(prefix.suffix(2))/\(shortenedName)": Data(nameFileContent.utf8)
			]
		}

		@Test
		func fetchItemMetadataWithLongName() async throws {
			let metadata = try await decorator.fetchItemMetadata(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
			#expect(metadata.name == "File 6 (Long)")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/Directory 3 (Long)/File 6 (Long)")
		}

		@Test
		func fetchItemListForSubDirWithLongName() async throws {
			let itemList = try await decorator.fetchItemList(forFolderAt: CloudPath("/Directory 3 (Long)"), withPageToken: nil)
			#expect(itemList.items.count == 2)
			#expect(itemList.items.contains(where: { $0.name == "File 6 (Long)" }))
			#expect(itemList.items.contains(where: { $0.name == "Directory 4 (Long)" }))
		}

		@Test
		func fetchItemListWithCancelledNameLookup() async throws {
			provider.transferHook = { cloudPath, _ in
				if cloudPath.path == "pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng" {
					throw CancellationError()
				}
			}
			await #expect(throws: CancellationError.self) { try await decorator.fetchItemList(forFolderAt: CloudPath("/"), withPageToken: nil) }
		}

		/// The name files of these names would lie in other directories than `m/<2 characters>/<2 characters>`, where the mock holds them.
		@Test
		func fetchItemListSkipsNamesThatAreNoDeflatedNames() async throws {
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
			#expect(itemList.items.map(\.cloudPath.path) == ["\(dirPath)/file1"])
			#expect(!provider.calls.contains("downloadFile"))
			#expect(provider.moved.isEmpty)
		}

		@Test
		func fetchItemListWithOnlyInvalidNamesIsEmpty() async throws {
			let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
				"\(dirPath)/..AB.lng": Data(),
				"\(dirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data(),
				"pathToVault/m/4H/GU/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data("..".utf8)
			])
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.isEmpty)
		}

		/// The swapped name files hold valid names, so only the comparison with the listed name leaves their items out.
		@Test
		func fetchItemListSkipsNamesWhoseNameFileBelongsToAnotherName() async throws {
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
			#expect(itemList.items.map(\.cloudPath.path) == ["\(dirPath)/\(longName)"])
			#expect(provider.moved.isEmpty)
		}

		/// Both name files hold the name that hashes to their `.lng` name, so only the size leaves the larger one out.
		@Test
		func fetchItemListSkipsNamesWhoseNameFileIsTooLarge() async throws {
			let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			let longestName = String(repeating: "a", count: vaultNameFileMaxLength)
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
				"\(dirPath)/GX36U5MEL5HOKVCAWLUURFYCRAVHZ5CY.lng": Data(),
				"\(dirPath)/57IHRLSOPZN3LK6DXOYTGLXGIBW4MJMB.lng": Data(),
				"pathToVault/m/GX/36/GX36U5MEL5HOKVCAWLUURFYCRAVHZ5CY.lng": Data(longestName.utf8),
				"pathToVault/m/57/IH/57IHRLSOPZN3LK6DXOYTGLXGIBW4MJMB.lng": Data(String(repeating: "a", count: vaultNameFileMaxLength + 1).utf8)
			])
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.map(\.cloudPath.path) == ["\(dirPath)/\(longestName)"])
			#expect(provider.moved.isEmpty)
		}

		@Test
		func fetchItemListMovesLegacyShortenedNameToOriginalName() async throws {
			let provider = makeProviderWithLegacyShortenedName()
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)
			#expect(provider.moved == ["\(legacyDirPath)/\(legacyShortenedName)": "\(legacyDirPath)/\(legacyOriginalName)"])
			#expect([legacyOriginalName] == itemList.items.map(\.name))
			#expect(itemList.items.map(\.cloudPath.path) == ["\(legacyDirPath)/\(legacyOriginalName)"])
			#expect(itemList.items.map(\.itemType) == [.file])
		}

		/// The legacy name is the only item, so the listing would throw if a failed move counted as a failed item.
		@Test
		func fetchItemListLeavesOutLegacyShortenedNameThatCannotBeMoved() async throws {
			for error in [CloudProviderError.itemAlreadyExists, .unauthorized, .itemNotFound] {
				let provider = makeProviderWithLegacyShortenedName()
				provider.moveHook = { throw error }
				let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
				let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)
				#expect(itemList.items.isEmpty, "\(error)")
			}
		}

		@Test
		func fetchItemListReturnsLegacyShortenedNameWhoseMoveLeftLeftovers() async throws {
			let provider = makeProviderWithLegacyShortenedName()
			provider.afterMutationHook = CloudProviderMock.failing("moveFile", with: CloudProviderError.moveCompletedWithSourceRemaining)
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)
			#expect(itemList.items.map(\.cloudPath.path) == ["\(legacyDirPath)/\(legacyOriginalName)"])
		}

		/// A missing internet connection says nothing about whether the item can be moved, so it counts like a name file that couldn't be downloaded.
		@Test
		func fetchItemListWithLegacyShortenedNameThrowsIfMoveFailsWithoutInternetConnection() async throws {
			let provider = makeProviderWithLegacyShortenedName()
			provider.moveHook = { throw CloudProviderError.noInternetConnection }
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CloudProviderError.noInternetConnection) { try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil) }
		}

		/// The legacy name is listed last, so the listing throws the lookup's error only if the failed move is skipped.
		@Test
		func fetchItemListWithUnmovedLegacyShortenedNameAndFailedNameLookupThrows() async throws {
			let provider = makeProviderWithLegacyShortenedName(files: ["\(legacyDirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data()])
			provider.moveHook = { throw CloudProviderError.unauthorized }
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CloudProviderError.itemNotFound) { try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil) }
		}

		/**
		 A provider that checks the source first reports the moved item as `itemNotFound`, one that checks the target first as `itemAlreadyExists`.

		 The test seeds the name that the item was moved to with another size than the shortened name, so that the size shows whose metadata the listing returns. The mock's files don't change. With a page size of 2 the page therefore holds both names, like a page listed during a move that copies and then deletes, and the listing returns the item once. The original name sorts before the shortened one, and the mock's page token is the start index, so with a page size of 1 the page at token `1` holds only the shortened name, like a page listed before the move.

		 The shortened name stays readable, as through a stale cached ID or during a move that copies and then deletes. The metadata hook checks that the listing returns the original's metadata without reading the shortened name.
		 */
		@Test
		func fetchItemListReturnsLegacyShortenedNameThatAnotherListingMoved() async throws {
			let shortenedPath = CloudPath("\(legacyDirPath)/\(legacyShortenedName)")
			let pages: [(pageToken: String?, listedNames: [String])] = [(nil, [legacyOriginalName, legacyShortenedName]), ("1", [legacyShortenedName])]
			for error in [CloudProviderError.itemNotFound, .itemAlreadyExists] {
				for page in pages {
					let provider = makeProviderWithLegacyShortenedName(files: ["\(legacyDirPath)/\(legacyOriginalName)": Data(count: 7)], maxPageSize: page.listedNames.count)
					provider.moveHook = { throw error }
					provider.metadataHook = { cloudPath in
						#expect(cloudPath != shortenedPath)
					}
					let listedItems = try await provider.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: page.pageToken).items
					#expect(page.listedNames == listedItems.map(\.name))
					let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
					let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: page.pageToken)
					#expect(itemList.items.map(\.cloudPath.path) == ["\(legacyDirPath)/\(legacyOriginalName)"], "\(error), page size \(page.listedNames.count)")
					#expect(itemList.items.map(\.name) == [legacyOriginalName], "\(error), page size \(page.listedNames.count)")
					#expect(itemList.items.map(\.size) == [7], "\(error), page size \(page.listedNames.count)")
				}
			}
		}

		/// The metadata override reports at the original name either another name, as a stale cached ID on Box, Microsoft Graph or pCloud can, or the original name spelled with U+212A KELVIN SIGN, which equals it as a `String` but not by bytes. The test seeds the original name only so that, with a page size of 1, the page at token `1` holds only the shortened name.
		@Test
		func fetchItemListLeavesOutLegacyShortenedNameWhoseOriginalNameReportsAnotherName() async throws {
			let cases = [
				ReportedLegacyName(originalName: legacyOriginalName, shortenedName: legacyShortenedName, reportedName: "0" + String(repeating: "B", count: 128)),
				ReportedLegacyName(originalName: legacyOriginalNameWithK, shortenedName: legacyShortenedNameWithK, reportedName: legacyOriginalNameWithKelvinSign)
			]
			for testCase in cases {
				let originalPath = CloudPath("\(legacyDirPath)/\(testCase.originalName)")
				for error in [CloudProviderError.itemNotFound, .itemAlreadyExists] {
					let files = legacyFiles(testCase.shortenedName, nameFileContent: testCase.originalName).merging([originalPath.path: Data()]) { $1 }
					let provider = CloudProviderMock(folders: legacyFolders, files: files, maxPageSize: 1)
					provider.moveHook = { throw error }
					provider.metadataOverride = { cloudPath in
						cloudPath == originalPath ? CloudItemMetadata(name: testCase.reportedName, cloudPath: originalPath, itemType: .file, lastModifiedDate: nil, size: nil) : nil
					}
					let listedItems = try await provider.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: "1").items
					#expect(listedItems.map(\.name) == [testCase.shortenedName])
					let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
					let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: "1")
					#expect(itemList.items.isEmpty, "\(error), \(testCase.shortenedName)")
				}
			}
		}

		/**
		 A name file written outside Cryptomator can hold the original name with U+212A KELVIN SIGN, which shortens to the same name as the original name that the page lists. The mock finds a fixture item by `String` equality, so the lookup of that spelling reports the original item under the requested spelling, as Google Drive reports a name.

		 The duplicate filter keeps a path's first entry, and the mock lists the original name first, so the provider reverses its pages to let the restored spelling come first.
		 */
		@Test
		func fetchItemListKeepsOriginalNameWhenALegacyNameRestoresToACanonicallyEquivalentSpelling() async throws {
			let files = legacyFiles(legacyShortenedNameWithK, nameFileContent: legacyOriginalNameWithKelvinSign).merging(["\(legacyDirPath)/\(legacyOriginalNameWithK)": Data()]) { $1 }
			let provider = ReversedListingCloudProviderMock(folders: legacyFolders, files: files)
			provider.moveHook = { throw CloudProviderError.itemAlreadyExists }
			let listedItems = try await provider.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil).items
			#expect(listedItems.map(\.name) == [legacyShortenedNameWithK, legacyOriginalNameWithK])
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil)
			#expect(itemList.items.map { Array($0.name.utf8) } == [Array(legacyOriginalNameWithKelvinSign.utf8), Array(legacyOriginalNameWithK.utf8)])
		}

		@Test
		func fetchItemListWithCancelledMoveOfLegacyShortenedName() async throws {
			try await assertFetchItemListOfLegacyShortenedNameThrowsCancellationError { $0.moveHook = { throw CancellationError() } }
		}

		@Test
		func fetchItemListWithCancelledLookupOfMovedLegacyShortenedName() async throws {
			try await assertFetchItemListOfLegacyShortenedNameThrowsCancellationError { provider in
				provider.moveHook = { throw CloudProviderError.itemNotFound }
				provider.metadataHook = { _ in throw CancellationError() }
			}
		}

		private func assertFetchItemListOfLegacyShortenedNameThrowsCancellationError(_ configure: (CloudProviderMock) -> Void) async throws {
			let provider = makeProviderWithLegacyShortenedName()
			configure(provider)
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CancellationError.self) { try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(legacyDirPath), withPageToken: nil) }
		}

		/// The invalid name is listed last, so the listing throws the lookup's error only if `invalidNameFile` is skipped.
		@Test
		func fetchItemListWithInvalidNamesAndFailedNameLookupThrows() async throws {
			let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
				"\(dirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data(),
				"\(dirPath)/AB...lng": Data()
			])
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CloudProviderError.itemNotFound) { try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil) }
		}

		/// The `.lng` suffix forms one `Character` with a prepended mark before it, but it still marks a shortened name. This one isn't a valid one, so the listing leaves it out.
		@Test
		func fetchItemListLeavesOutInvalidNameWhoseSuffixIsInCombinedCharacter() async throws {
			let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: ["\(dirPath)/AB\u{600}.lng": Data(), "\(dirPath)/file1": Data()])
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let itemList = try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil)
			#expect(itemList.items.map(\.cloudPath.path) == ["\(dirPath)/file1"])
		}

		/// The invalid name doesn't count as restored, so the listing throws the lookup's error.
		@Test
		func fetchItemListWithInvalidNameWhoseSuffixIsInCombinedCharacterAndFailedNameLookupThrows() async throws {
			let dirPath = "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/00", dirPath], files: [
				"\(dirPath)/4HGUG7WD5CTA3M2ODUKQUT6HHCBNQO2B.lng": Data(),
				"\(dirPath)/AB\u{600}.lng": Data()
			])
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			await #expect(throws: CloudProviderError.itemNotFound) { try await shorteningDecorator.fetchItemList(forFolderAt: CloudPath(dirPath), withPageToken: nil) }
		}

		@Test
		func downloadFileWithLongName() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let metadata = try await decorator.downloadFile(from: CloudPath("/File 4 (Long)"), to: localURL)
			let cleartext = try String(contentsOf: localURL, encoding: .utf8)
			#expect(cleartext == "cleartext4")
			#expect(metadata.name == "File 4 (Long)")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 4 (Long)")
			#expect(provider.lastModifiedDate == metadata.lastModifiedDate)
			#expect(metadata.size == 10)
		}

		@Test
		func downloadFileWithLongNameKeepsAliasMarker() async throws {
			let dirPath = "pathToVault/d/11/BBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
			let lngPath = "\(dirPath)/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"
			let provider = CloudProviderMock(folders: ["pathToVault", "pathToVault/d", "pathToVault/d/11", dirPath], files: [lngPath: Data("dir3-id".utf8)], aliasedDownloads: [lngPath])
			let shorteningDecorator = try VaultFormat6ShorteningProviderDecorator(delegate: provider, vaultPath: vaultPath)
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			let metadata = try await shorteningDecorator.downloadFile(from: CloudPath("\(dirPath)/0\(String(repeating: "dir3", count: 33))"), to: localURL)
			#expect(metadata.isAlias)
		}

		@Test
		func uploadFileWithLongName() async throws {
			let localURL = tmpDirURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
			try "cleartext4".write(to: localURL, atomically: true, encoding: .utf8)
			let metadata = try await decorator.uploadFile(from: localURL, to: CloudPath("/File 4 (Long)"), replaceExisting: false)
			#expect(provider.createdFolders.count == 3)
			#expect(provider.createdFolders.contains("pathToVault/m"))
			#expect(provider.createdFolders.contains("pathToVault/m/2Q"))
			#expect(provider.createdFolders.contains("pathToVault/m/2Q/OD"))
			#expect(provider.createdFiles.count == 2)
			#expect(Data("ciphertext4".utf8) == provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
			#expect(String(repeating: "file4", count: 26).data(using: .utf8) == provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
			#expect(metadata.name == "File 4 (Long)")
			#expect(metadata.itemType == .file)
			#expect(metadata.cloudPath.path == "/File 4 (Long)")
			#expect(provider.lastModifiedDate == metadata.lastModifiedDate)
			#expect(metadata.size == 0) // CryptorMock calculates a cleartext size of 0
		}

		@Test
		func createFolderWithLongName() async throws {
			try await decorator.createFolder(at: CloudPath("/Directory 3 (Long)"))
			#expect(provider.createdFolders.count == 5)
			#expect(provider.createdFolders.contains("pathToVault/m"))
			#expect(provider.createdFolders.contains("pathToVault/m/DL"))
			#expect(provider.createdFolders.contains("pathToVault/m/DL/2X"))
			#expect(provider.createdFolders.contains("pathToVault/d/99"))
			#expect(provider.createdFolders.contains("pathToVault/d/99/ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ"))
			#expect(provider.createdFiles.count == 2)
			#expect(provider.createdFiles["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"] != nil)
			#expect(Data("0\(String(repeating: "dir3", count: 33))".utf8) == provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
		}

		@Test
		func deleteFileWithLongName() async throws {
			try await decorator.deleteFile(at: CloudPath("/Directory 3 (Long)/File 6 (Long)"))
			#expect(provider.deleted.count == 1)
			#expect(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD/LTGFEUKABMKGWWR2EAL6LSHZC7OGDRMN.lng"))
		}

		@Test
		func deleteFolderWithLongName() async throws {
			try await decorator.deleteFolder(at: CloudPath("/Directory 3 (Long)"))
			#expect(provider.deleted.count == 3)
			#expect(provider.deleted.contains("pathToVault/d/44/EEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"))
			#expect(provider.deleted.contains("pathToVault/d/33/DDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"))
			#expect(provider.deleted.contains("pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"))
		}

		@Test
		func moveFileFromShortToLongName() async throws {
			try await decorator.moveFile(from: CloudPath("/File 1"), to: CloudPath("/File 4 (Long)"))
			#expect(provider.createdFolders.count == 3)
			#expect(provider.createdFolders.contains("pathToVault/m"))
			#expect(provider.createdFolders.contains("pathToVault/m/2Q"))
			#expect(provider.createdFolders.contains("pathToVault/m/2Q/OD"))
			#expect(provider.createdFiles.count == 1)
			#expect(String(repeating: "file4", count: 26).data(using: .utf8) == provider.createdFiles["pathToVault/m/2Q/OD/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"])
			#expect(provider.moved.count == 1)
			#expect(provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng")
		}

		@Test
		func moveFileFromLongToShortName() async throws {
			try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 1"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/file1")
		}

		@Test
		func moveFileFromLongToLongName() async throws {
			try await decorator.moveFile(from: CloudPath("/File 4 (Long)"), to: CloudPath("/File 5 (Long)"))
			#expect(provider.createdFolders.count == 3)
			#expect(provider.createdFolders.contains("pathToVault/m"))
			#expect(provider.createdFolders.contains("pathToVault/m/CI"))
			#expect(provider.createdFolders.contains("pathToVault/m/CI/VV"))
			#expect(provider.createdFiles.count == 1)
			#expect(String(repeating: "file5", count: 26).data(using: .utf8) == provider.createdFiles["pathToVault/m/CI/VV/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng"])
			#expect(provider.moved.count == 1)
			#expect(provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/2QODSHBUSLEFQ6UELQ45EKJ27HTAMZPH.lng"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/CIVVSN3UPME74I7TGQESFYRUFKAUH6H7.lng")
		}

		@Test
		func moveFolderFromShortToLongName() async throws {
			try await decorator.moveFolder(from: CloudPath("/Directory 1"), to: CloudPath("/Directory 3 (Long)"))
			#expect(provider.createdFolders.count == 3)
			#expect(provider.createdFolders.contains("pathToVault/m"))
			#expect(provider.createdFolders.contains("pathToVault/m/DL"))
			#expect(provider.createdFolders.contains("pathToVault/m/DL/2X"))
			#expect(provider.createdFiles.count == 1)
			#expect(Data("0\(String(repeating: "dir3", count: 33))".utf8) == provider.createdFiles["pathToVault/m/DL/2X/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"])
			#expect(provider.moved.count == 1)
			#expect(provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng")
		}

		@Test
		func moveFolderFromLongToShortName() async throws {
			try await decorator.moveFolder(from: CloudPath("/Directory 3 (Long)"), to: CloudPath("/Directory 1"))
			#expect(provider.moved.count == 1)
			#expect(provider.moved["pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/DL2XHF4PL5BKUCEJFIOEWB5JPAURMP3Y.lng"] == "pathToVault/d/00/AAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/0dir1")
		}

		@Test
		func shorteningDecoratorThrowsCancellationErrorInCancelledTask() async {
			await assertThrowsCancellationErrorInCancelledTask(shorteningDecorator)
			#expect(provider.calls == [])
		}
	}
}

/// A legacy name and the name that the lookup of its original name reports.
private struct ReportedLegacyName {
	let originalName: String
	let shortenedName: String
	let reportedName: String
}

/// Lists each page in reverse order. `@unchecked Sendable`: restates the conformance of `CloudProviderMock`; this subclass adds no state.
private final class ReversedListingCloudProviderMock: CloudProviderMock, @unchecked Sendable {
	@concurrent
	override func fetchItemList(forFolderAt cloudPath: CloudPath, withPageToken pageToken: String?) async throws -> CloudItemList {
		let itemList = try await super.fetchItemList(forFolderAt: cloudPath, withPageToken: pageToken)
		return CloudItemList(items: itemList.items.reversed(), nextPageToken: itemList.nextPageToken)
	}
}
