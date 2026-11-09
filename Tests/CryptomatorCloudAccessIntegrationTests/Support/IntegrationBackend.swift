//
//  IntegrationBackend.swift
//  CryptomatorCloudAccessIntegrationTests
//
//  Created by Tobias Hagemann on 15.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation
import Testing

enum IntegrationProvider: String, CaseIterable, Codable, Sendable {
	case box
	case dropbox
	case googleDrive = "googledrive"
	case microsoftGraph = "microsoftgraph"
	case pCloud = "pcloud"
	case s3
	case webDAV = "webdav"
	case localFileSystem = "localfilesystem"

	/// How many test attempts and fixture build steps may talk to this provider's account at the same time.
	var concurrencyLimit: Int {
		switch self {
		case .dropbox, .pCloud:
			// Dropbox contends for write locks, pCloud times out under load
			return 2
		case .localFileSystem:
			return 8
		default:
			return 4
		}
	}

	var isRemote: Bool {
		return self != .localFileSystem
	}

	var isEventuallyConsistent: Bool {
		return self == .s3 || self == .pCloud
	}

	var supportsPagination: Bool {
		return self != .pCloud
	}
}

enum IntegrationVaultFormat: String, CaseIterable, Codable, Sendable {
	case plain
	case vf6
	case vf7
}

struct IntegrationBackend: Hashable, Codable, Sendable, CustomTestStringConvertible {
	let kind: IntegrationProvider
	let format: IntegrationVaultFormat

	/// The token that selects this backend in `INTEGRATION_BACKENDS`, e.g. `pcloud-vf7`.
	var token: String {
		return "\(kind.rawValue)-\(format.rawValue)"
	}

	var testDescription: String {
		return token
	}

	init(_ kind: IntegrationProvider, _ format: IntegrationVaultFormat) {
		self.kind = kind
		self.format = format
	}
}

// MARK: - Selection

extension IntegrationBackend {
	static let all: [IntegrationBackend] = IntegrationProvider.allCases.flatMap { kind in
		IntegrationVaultFormat.allCases.map { IntegrationBackend(kind, $0) }
	}

	private static let noneToken = "none"

	/// The tokens of `INTEGRATION_BACKENDS`: comma-separated provider tokens (`pcloud`) or backend tokens (`pcloud-vf7`). Unset or empty selects all backends, `none` selects none.
	private static let filterTokens: [String] = (ProcessInfo.processInfo.environment["INTEGRATION_BACKENDS"] ?? "")
		.split(separator: ",")
		.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
		.filter { !$0.isEmpty }

	static let invalidTokens: [String] = filterTokens.filter { token in
		token != noneToken && IntegrationProvider(rawValue: token) == nil && !all.contains { $0.token == token }
	}

	static let validTokens: [String] = [noneToken] + IntegrationProvider.allCases.map(\.rawValue) + all.map(\.token)

	static let selectsNone = filterTokens.contains(noneToken)

	static let selected: [IntegrationBackend] = {
		if filterTokens.isEmpty {
			return all
		}
		return all.filter { filterTokens.contains($0.kind.rawValue) || filterTokens.contains($0.token) }
	}()

	static let selectedPlain: [IntegrationBackend] = selected.filter { $0.format == .plain }

	static let selectedPlainRemote: [IntegrationBackend] = selectedPlain.filter(\.kind.isRemote)

	static let selectedPaginating: [IntegrationBackend] = selected.filter(\.kind.supportsPagination)

	static let selectedVaults: [IntegrationBackend] = selected.filter { $0.format != .plain }

	static func isSelected(_ kind: IntegrationProvider) -> Bool {
		return selected.contains { $0.kind == kind }
	}
}
