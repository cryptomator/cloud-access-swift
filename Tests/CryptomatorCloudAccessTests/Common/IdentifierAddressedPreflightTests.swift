//
//  IdentifierAddressedPreflightTests.swift
//  CryptomatorCloudAccessTests
//
//  Created by Tobias Hagemann on 22.11.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import os
import Testing
@testable import CryptomatorCloudAccessCore

extension UnitTests {
	/// Runs the preflight on a cache of Box items, which holds the folder `/folder` (`D`), the file `/file` (`F`), the symbolic link `/link` (`L`) and the item `/unknown` (`U`) of an unknown type.
	final class IdentifierAddressedPreflightTests {
		private let cache: IdentifierCache<BoxItem>
		private let lookups = LookupRecorder()
		private let tmpDirURL: URL

		init() throws {
			self.cache = try IdentifierCache<BoxItem>()
			for (path, identifier, itemType) in [("/folder", "D", CloudItemType.folder), ("/file", "F", .file), ("/link", "L", .symlink), ("/unknown", "U", .unknown)] {
				try cache.addOrUpdate(BoxItem(cloudPath: CloudPath(path), identifier: identifier, itemType: itemType))
			}
			self.tmpDirURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
			try FileManager.default.createDirectory(at: tmpDirURL, withIntermediateDirectories: true)
		}

		deinit {
			removeItemRecordingFailure(at: tmpDirURL)
		}

		// MARK: - Root and Paths

		@Test
		func rootTargetThrowsItemAlreadyExistsAndRootSourceItemTypeMismatchWithoutLookup() async throws {
			let preflight = makePreflight()
			let localURL = try makeLocalFile()

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await preflight.prepareCreateFolder(at: .root) }
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await preflight.prepareUpload(from: localURL, to: .root, replaceExisting: true) }
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await preflight.prepareMove(from: CloudPath("/file"), to: .root, type: .file, operation: "moveFile") }
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await preflight.prepareMove(from: .root, to: CloudPath("/x"), type: .folder, operation: "moveFolder") }
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await preflight.prepareMove(from: .root, to: .root, type: .folder, operation: "moveFolder") }
			#expect(lookups.calls.isEmpty)
		}

		@Test
		func missingLocalFileThrowsItemNotFoundBeforeRootTarget() async throws {
			await #expect(throws: CloudProviderError.itemNotFound) { try await makePreflight().prepareUpload(from: tmpDirURL.appendingPathComponent("missing"), to: .root, replaceExisting: true) }
		}

		@Test
		func pathsThatNeverReachRootThrowWithoutLookup() async throws {
			let preflight = makePreflight()

			for path in ["/../x", "a/b", "x"] {
				await #expect(throws: CloudProviderError.parentFolderDoesNotExist, "\(path)") { try await preflight.prepareCreateFolder(at: CloudPath(path)) }
				await #expect(throws: CloudProviderError.itemNotFound, "\(path)") { try await preflight.resolve(at: CloudPath(path)) }
				await #expect(throws: CloudProviderError.itemNotFound, "\(path)") { try await preflight.prepareMove(from: CloudPath(path), to: CloudPath("/other/new"), type: .file, operation: "moveFile") }
			}
			#expect(lookups.calls.isEmpty)
		}

		/// A decoded path keeps its spelling, whereas its parent is standardized: the parents of `/folder/../new` and `/./x` would become the root, and the parent of `/folder/.` is `..`, which never reaches it.
		@Test(arguments: ["/folder/../new", "/folder/.", "/./x", "/folder//new", "/folder/new/"])
		func decodedPathThatIsNoCanonicalPathThrowsWithoutLookup(path: String) async throws {
			let decodedPath = try JSONDecoder().decode(CloudPath.self, from: Data(#"{"path":"\#(path)"}"#.utf8))
			try #require(decodedPath.path == path)
			let preflight = makePreflight()

			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareCreateFolder(at: decodedPath) }
			await #expect(throws: CloudProviderError.itemNotFound) { try await preflight.resolve(at: decodedPath) }
			await #expect(throws: CloudProviderError.itemNotFound) { try await preflight.resolveSource(at: decodedPath, type: .file, operation: "deleteFile") }
			#expect(lookups.calls.isEmpty)
			#expect(cache.get(.root) == BoxItem.rootItem)
		}

		// MARK: - Folders on the Path

		@Test
		func itemOnPathThatIsNoFolderIsNeverLookedIn() async throws {
			let preflight = makePreflight()
			let localURL = try makeLocalFile()

			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareCreateFolder(at: CloudPath("/file/new")) }
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareCreateFolder(at: CloudPath("/file/x/new")) }
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareUpload(from: localURL, to: CloudPath("/link/new"), replaceExisting: false) }
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareMove(from: CloudPath("/folder"), to: CloudPath("/unknown/new"), type: .folder, operation: "moveFolder") }
			await #expect(throws: CloudProviderError.itemNotFound) { try await preflight.resolve(at: CloudPath("/file/x")) }
			#expect(lookups.calls.isEmpty)
		}

		// MARK: - Sources

		@Test
		func sourceOfOtherTypeThrowsItemTypeMismatchAndLogsOnce() async throws {
			let logCapture = LogCapture.start()
			defer {
				logCapture.stop()
			}
			let preflight = makePreflight()
			let mismatches: [(path: String, type: CloudItemType)] = [("/folder", .file), ("/file", .folder), ("/link", .folder), ("/unknown", .file), ("/unknown", .folder)]

			for (path, type) in mismatches {
				let operation = "delete\(type)"
				await #expect(throws: CloudProviderError.itemTypeMismatch, "\(path) as \(type)") { try await preflight.resolveSource(at: CloudPath(path), type: type, operation: operation) }
				#expect(logCapture.messages.count(where: { $0.hasPrefix("TestProvider: \(operation)(at: \(path)) failed with error:") }) == 1, "\(path) as \(type)")
			}
			await #expect(throws: CloudProviderError.itemTypeMismatch) { try await preflight.prepareMove(from: CloudPath("/folder"), to: CloudPath("/moved"), type: .file, operation: "moveFile") }
			#expect(logCapture.messages.count(where: { $0.hasPrefix("TestProvider: moveFile(at: /folder) failed with error:") }) == 1)
			#expect(lookups.calls.isEmpty)
		}

		@Test
		func symbolicLinkIsSourceOfFileOperation() async throws {
			let item = try await makePreflight().resolveSource(at: CloudPath("/link"), type: .file, operation: "deleteFile")

			#expect(item.identifier == "L")
		}

		/// The folder's cached row changes while the source is looked up in it, so the source is looked up again in the new folder, and the returned parent is the folder that it was found in.
		@Test
		func sourceIsPairedWithFolderItWasFoundIn() async throws {
			let cache = cache
			let preflight = makePreflight { name, folderItem in
				if folderItem.identifier == "D" {
					try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder"), identifier: "E", itemType: .folder))
				}
				return name == "b" ? nil : BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "\(folderItem.identifier)/\(name)", itemType: .file)
			}

			let move = try await preflight.prepareMove(from: CloudPath("/folder/a"), to: CloudPath("/b"), type: .file, operation: "moveFile")

			#expect(lookups.calls == ["D/a", "E/a", "0/b"])
			#expect(move.source.identifier == "E/a")
			#expect(move.sourceParent.identifier == "E")
		}

		/// The folder at the path was replaced after the target's folder was resolved, while the source was looked up, so the move would enter or leave a folder that is no longer at the path.
		@Test
		func moveWithinReplacedFolderThrowsInconsistentCacheBeforeTargetLookup() async throws {
			let cache = cache
			let preflight = makePreflight { name, folderItem in
				if folderItem.identifier == "D" {
					try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder"), identifier: "E", itemType: .folder))
				}
				return BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "\(folderItem.identifier)/\(name)", itemType: .file)
			}

			await #expect(throws: BoxError.inconsistentCache) { try await preflight.prepareMove(from: CloudPath("/folder/a"), to: CloudPath("/folder/b"), type: .file, operation: "moveFile") }
			#expect(lookups.calls == ["D/a", "E/a"])
		}

		/// A write without the parent check can cache an item after its folder's row was removed, and the move looks the missing rows up instead of failing.
		@Test
		func sourceCachedWithoutFolderRowIsLookedUpAgain() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/gone/x"), identifier: "X", itemType: .file))
			let preflight = makePreflight { name, folderItem in
				switch name {
				case "gone": BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "G", itemType: .folder)
				case "x": BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "G/x", itemType: .file)
				default: nil
				}
			}

			let move = try await preflight.prepareMove(from: CloudPath("/gone/x"), to: CloudPath("/y"), type: .file, operation: "moveFile")

			#expect(lookups.calls == ["0/gone", "G/x", "0/y"])
			#expect(move.source.identifier == "G/x")
			#expect(move.sourceParent.identifier == "G")
		}

		/// A shared ancestor of the source and the target's folder was replaced while the source was looked up, so the target's folder left the path although the two folders have different paths.
		@Test
		func moveIntoFolderBelowReplacedAncestorThrowsInconsistentCacheBeforeTargetLookup() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder/sub"), identifier: "S", itemType: .folder))
			let cache = cache
			let preflight = makePreflight { name, folderItem in
				if folderItem.identifier == "D" {
					try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder"), identifier: "E", itemType: .folder))
				}
				return BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "\(folderItem.identifier)/\(name)", itemType: .file)
			}

			await #expect(throws: BoxError.inconsistentCache) { try await preflight.prepareMove(from: CloudPath("/folder/a"), to: CloudPath("/folder/sub/b"), type: .file, operation: "moveFile") }
			#expect(lookups.calls == ["D/a", "E/a"])
		}

		/// Folder names that are canonically equivalent but spelled with other bytes name two folders, so a move between them is no rename within one folder.
		@Test
		func moveBetweenCanonicallyEquivalentFolderNamesUsesBothFolders() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/\u{E9}"), identifier: "E1", itemType: .folder))
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/e\u{301}"), identifier: "E2", itemType: .folder))
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/\u{E9}/a"), identifier: "A", itemType: .file))

			let move = try await makePreflight().prepareMove(from: CloudPath("/\u{E9}/a"), to: CloudPath("/e\u{301}/b"), type: .file, operation: "moveFile")

			#expect(move.sourceParent.identifier == "E1")
			#expect(move.targetParent.identifier == "E2")
			#expect(lookups.calls == ["E2/b"])
		}

		/// The ancestor of the target's folder was removed while the source was looked up, and a write without the parent check cached the target's folder again, so it is the row at its path but may have moved with the ancestor.
		@Test
		func moveIntoFolderLeftWithoutAncestorRowThrowsInconsistentCacheBeforeTargetLookup() async throws {
			let folder = BoxItem(cloudPath: CloudPath("/folder"), identifier: "D", itemType: .folder)
			let subfolder = BoxItem(cloudPath: CloudPath("/folder/sub"), identifier: "S", itemType: .folder)
			try cache.addOrUpdate(subfolder)
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/other"), identifier: "O", itemType: .folder))
			let cache = cache
			let preflight = makePreflight { name, folderItem in
				try cache.invalidate(folder)
				try cache.addOrUpdate(subfolder)
				return BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "\(folderItem.identifier)/\(name)", itemType: .file)
			}

			await #expect(throws: BoxError.inconsistentCache) { try await preflight.prepareMove(from: CloudPath("/other/a"), to: CloudPath("/folder/sub/b"), type: .file, operation: "moveFile") }
			#expect(cache.get(subfolder.cloudPath) == subfolder)
			#expect(lookups.calls == ["O/a"])
		}

		/// The target's folder is looked up and cached at a path that held no row while an item cached below it without its row remains from a write without the parent check, so that item is dropped and looked up in the folder.
		@Test
		func folderCachedIntoEmptySlotDropsItemsLeftBelowIt() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/p/x"), identifier: "X", itemType: .file))
			let preflight = makePreflight { name, folderItem in
				switch name {
				case "p": BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "P", itemType: .folder)
				case "x": BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "P/x", itemType: .file)
				default: nil
				}
			}

			let move = try await preflight.prepareMove(from: CloudPath("/p/x"), to: CloudPath("/p/y"), type: .file, operation: "moveFile")

			#expect(lookups.calls == ["0/p", "P/x", "P/y"])
			#expect(move.source.identifier == "P/x")
		}

		/// A delete never addresses an item cached without its folder's row, which may have moved with a folder that left the path.
		@Test
		func deleteLooksUpItemCachedWithoutFolderRow() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/gone/x"), identifier: "X", itemType: .file))
			let preflight = makePreflight { name, folderItem in
				switch name {
				case "gone": BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "G", itemType: .folder)
				case "x": BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "G/x", itemType: .file)
				default: nil
				}
			}

			let item = try await preflight.resolveSource(at: CloudPath("/gone/x"), type: .file, operation: "deleteFile")

			#expect(lookups.calls == ["0/gone", "G/x"])
			#expect(item.identifier == "G/x")
		}

		/// A folder cached without its folder's row may have moved with a folder that left the path, so a delete below it never looks in it.
		@Test
		func deleteBelowFolderCachedWithoutFolderRowLooksUpWholePath() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/gone/sub"), identifier: "S", itemType: .folder))
			let preflight = makePreflight { name, folderItem in
				BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "\(folderItem.identifier)/\(name)", itemType: name == "x" ? .file : .folder)
			}

			let item = try await preflight.resolveSource(at: CloudPath("/gone/sub/x"), type: .file, operation: "deleteFile")

			#expect(lookups.calls == ["0/gone", "0/gone/sub", "0/gone/sub/x"])
			#expect(item.identifier == "0/gone/sub/x")
		}

		/// A write never goes into a folder cached without its folder's row, which may have moved with a folder that left the path.
		@Test
		func writeIntoFolderCachedWithoutFolderRowLooksUpWholePath() async throws {
			let orphan = BoxItem(cloudPath: CloudPath("/gone/sub"), identifier: "S", itemType: .folder)
			try cache.addOrUpdate(orphan)
			let preflight = makePreflight { name, folderItem in
				name == "new" ? nil : BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "\(folderItem.identifier)/\(name)", itemType: .folder)
			}

			let parentItem = try await preflight.prepareCreateFolder(at: CloudPath("/gone/sub/new"))
			try cache.invalidate(BoxItem(cloudPath: CloudPath("/gone"), identifier: "0/gone", itemType: .folder))
			try cache.addOrUpdate(orphan)
			let move = try await preflight.prepareMove(from: CloudPath("/file"), to: CloudPath("/gone/sub/new"), type: .file, operation: "moveFile")

			#expect(parentItem.identifier == "0/gone/sub")
			#expect(move.targetParent.identifier == "0/gone/sub")
			#expect(lookups.calls == ["0/gone", "0/gone/sub", "0/gone/sub/new", "0/gone", "0/gone/sub", "0/gone/sub/new"])
		}

		/// The root has no parent folder, so a delete of the root resolves it directly and leaves the decision to the server.
		@Test
		func rootDeleteResolvesRootWithoutLookup() async throws {
			let item = try await makePreflight().resolveSource(at: .root, type: .folder, operation: "deleteFolder")

			#expect(item.identifier == BoxItem.rootItem.identifier)
			#expect(lookups.calls.isEmpty)
		}

		/// A folder cached below a file, e.g., by a listing that is still running when another client replaces the folder with a file, is never resolved, read or written into.
		@Test
		func folderCachedBelowFileIsNeverUsed() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/file/sub"), identifier: "S", itemType: .folder))
			let preflight = makePreflight { name, folderItem in
				BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "\(folderItem.identifier)/\(name)", itemType: .folder)
			}

			await #expect(throws: CloudProviderError.itemNotFound) { try await preflight.resolve(at: CloudPath("/file/sub")) }
			await #expect(throws: CloudProviderError.itemNotFound) { try await preflight.resolveSource(at: CloudPath("/file/sub/x"), type: .file, operation: "deleteFile") }
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareCreateFolder(at: CloudPath("/file/sub/new")) }
			#expect(lookups.calls.isEmpty)
		}

		// MARK: - Moves

		@Test
		func missingTargetParentThrowsBeforeSourceIsResolved() async throws {
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await makePreflight().prepareMove(from: CloudPath("/a"), to: CloudPath("/missing/b"), type: .file, operation: "moveFile") }
			#expect(lookups.calls == ["0/missing"])
		}

		@Test
		func missingSourceThrowsItemNotFoundWithoutTargetLookup() async throws {
			await #expect(throws: CloudProviderError.itemNotFound) { try await makePreflight().prepareMove(from: CloudPath("/a"), to: CloudPath("/folder/b"), type: .file, operation: "moveFile") }
			#expect(lookups.calls == ["0/a"])
		}

		@Test
		func moveLooksUpTargetAfterSource() async throws {
			let preflight = makePreflight { name, folderItem in
				name == "a" ? BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "A", itemType: .file) : nil
			}

			let move = try await preflight.prepareMove(from: CloudPath("/a"), to: CloudPath("/folder/b"), type: .file, operation: "moveFile")

			#expect(lookups.calls == ["0/a", "D/b"])
			#expect(move.source.identifier == "A")
			#expect(move.sourceParent == BoxItem.rootItem)
			#expect(move.targetParent.identifier == "D")
		}

		// MARK: - Targets

		/// The folder's cached row changes during the target's lookup, and the returned folder is still the one that the target was looked up in.
		@Test
		func targetIsJudgedInReturnedFolder() async throws {
			let cache = cache
			let preflight = makePreflight { _, _ in
				try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder"), identifier: "E", itemType: .folder))
				return nil
			}

			let parentItem = try await preflight.prepareCreateFolder(at: CloudPath("/folder/new"))

			#expect(lookups.calls == ["D/new"])
			#expect(parentItem.identifier == "D")
		}

		@Test
		func targetCheckIgnoresAndKeepsCachedRow() async throws {
			let cachedItem = BoxItem(cloudPath: CloudPath("/folder/gone"), identifier: "G", itemType: .folder)
			try cache.addOrUpdate(cachedItem)
			let preflight = makePreflight { name, folderItem in
				name == "taken" ? BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "T", itemType: .file) : nil
			}

			_ = try await preflight.prepareCreateFolder(at: CloudPath("/folder/gone"))
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await preflight.prepareCreateFolder(at: CloudPath("/folder/taken")) }

			#expect(lookups.calls == ["D/gone", "D/taken"])
			#expect(cache.get(cachedItem.cloudPath) == cachedItem)
			#expect(cache.get(CloudPath("/folder/taken")) == nil)
		}

		@Test
		func folderMissingAtTargetLookupThrowsParentFolderDoesNotExist() async throws {
			let preflight = makePreflight { _, _ in throw CloudProviderError.itemNotFound }
			let localURL = try makeLocalFile()

			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareCreateFolder(at: CloudPath("/folder/new")) }
			await #expect(throws: CloudProviderError.parentFolderDoesNotExist) { try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/new"), replaceExisting: true) }
		}

		// MARK: - Uploads

		@Test
		func uploadReplacesOnlyFileWithReplaceExisting() async throws {
			let localURL = try makeLocalFile()
			let preflight = makePreflight { name, folderItem in
				let itemType: CloudItemType = switch name {
				case "folder": .folder
				case "link": .symlink
				default: .file
				}
				return BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: name, itemType: itemType)
			}

			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/file"), replaceExisting: false) }
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/folder"), replaceExisting: true) }
			await #expect(throws: CloudProviderError.itemAlreadyExists) { try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/link"), replaceExisting: true) }
			let upload = try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/file"), replaceExisting: true)

			#expect(upload.file.size == 7)
			#expect(upload.parent.identifier == "D")
			#expect(upload.existing?.identifier == "file")
		}

		@Test
		func fastPathIsTriedOnlyForReplacingCachedFile() async throws {
			let localURL = try makeLocalFile()
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder/cached"), identifier: "C", itemType: .file))
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder/sub"), identifier: "S", itemType: .folder))
			let fastPathCalls = LookupRecorder()
			let fastPath: (BoxItem, BoxItem) async throws -> BoxItem? = { cachedItem, parentItem in
				fastPathCalls.record("\(parentItem.identifier)/\(cachedItem.identifier)")
				return cachedItem
			}
			let preflight = makePreflight()

			let existingItem = try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/cached"), replaceExisting: true, fastPath: fastPath).existing
			_ = try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/sub"), replaceExisting: true, fastPath: fastPath)
			_ = try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/cached"), replaceExisting: false, fastPath: fastPath)
			_ = try await preflight.prepareUpload(from: localURL, to: CloudPath("/folder/new"), replaceExisting: true, fastPath: fastPath)

			#expect(existingItem?.identifier == "C")
			#expect(fastPathCalls.calls == ["D/C"])
			#expect(lookups.calls == ["D/sub", "D/cached", "D/new"])
		}

		@Test
		func unconfirmedFastPathFallsBackToLookup() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder/cached"), identifier: "C", itemType: .file))
			let preflight = makePreflight { name, folderItem in
				BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "N", itemType: .file)
			}

			let existingItem = try await preflight.prepareUpload(from: makeLocalFile(), to: CloudPath("/folder/cached"), replaceExisting: true, fastPath: { _, _ in nil }).existing

			#expect(existingItem?.identifier == "N")
			#expect(lookups.calls == ["D/cached"])
		}

		@Test
		func fastPathErrorIsThrownWithoutLookup() async throws {
			try cache.addOrUpdate(BoxItem(cloudPath: CloudPath("/folder/cached"), identifier: "C", itemType: .file))

			await #expect(throws: CloudProviderError.unauthorized) { try await makePreflight().prepareUpload(from: makeLocalFile(), to: CloudPath("/folder/cached"), replaceExisting: true, fastPath: { _, _ in throw CloudProviderError.unauthorized }) }
			#expect(lookups.calls.isEmpty)
		}

		// MARK: - Cancellation

		/// A cancellation during the last lookup stops the mutation, which would otherwise send its request next.
		@Test
		func cancellationDuringLastLookupThrowsCancellationError() async throws {
			let localURL = try makeLocalFile()
			let operations: [(name: String, run: @Sendable (IdentifierAddressedPreflight<BoxItem>) async throws -> Void)] = [
				("createFolder", { _ = try await $0.prepareCreateFolder(at: CloudPath("/folder/new")) }),
				("upload", { _ = try await $0.prepareUpload(from: localURL, to: CloudPath("/folder/new"), replaceExisting: true) }),
				("move", { _ = try await $0.prepareMove(from: CloudPath("/file"), to: CloudPath("/folder/new"), type: .file, operation: "moveFile") }),
				("delete", { _ = try await $0.resolveSource(at: CloudPath("/folder/a"), type: .file, operation: "deleteFile") })
			]
			for (name, run) in operations {
				let cache = cache
				let task = Task {
					let preflight = IdentifierAddressedPreflight(cache: cache, providerName: "TestProvider") { name, folderItem in
						withUnsafeCurrentTask { $0?.cancel() }
						return name == "a" ? BoxItem(cloudPath: folderItem.cloudPath.appendingPathComponent(name), identifier: "A", itemType: .file) : nil
					}
					try await run(preflight)
				}

				await #expect(throws: CancellationError.self, "\(name)") { try await cancellingValue(of: task) }
			}
		}

		// MARK: - Helpers

		/// Creates a preflight whose lookups are recorded as `<folder identifier>/<name>`. Without `lookUp`, every name is free.
		private func makePreflight(lookUp: @escaping (String, BoxItem) async throws -> BoxItem? = { _, _ in nil }) -> IdentifierAddressedPreflight<BoxItem> {
			let lookups = lookups
			return IdentifierAddressedPreflight(cache: cache, providerName: "TestProvider") { name, folderItem in
				lookups.record("\(folderItem.identifier)/\(name)")
				return try await lookUp(name, folderItem)
			}
		}

		private func makeLocalFile() throws -> URL {
			let localURL = tmpDirURL.appendingPathComponent("local.txt")
			try Data("content".utf8).write(to: localURL)
			return localURL
		}
	}
}

private final class LookupRecorder: Sendable {
	private let recordedCalls = OSAllocatedUnfairLock(initialState: [String]())

	var calls: [String] {
		return recordedCalls.withLock { $0 }
	}

	func record(_ call: String) {
		recordedCalls.withLock { $0.append(call) }
	}
}
