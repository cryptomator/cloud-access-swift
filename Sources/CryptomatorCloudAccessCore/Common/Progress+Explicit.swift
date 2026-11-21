//
//  Progress+Explicit.swift
//  CryptomatorCloudAccess
//
//  Created by Tobias Hagemann on 13.10.26.
//  Copyright © 2026 Skymatic GmbH. All rights reserved.
//

import Foundation

extension Progress {
	private static let phasesTotalUnitCount: Int64 = 1000

	/**
	 Splits the progress that an operation received into one explicit child per phase.

	 The progress is reset to 1000 units, of which the phases share 999. The final unit stays reserved until `ProgressPhases.completeTransfer()`, so that the progress can't complete before the operation succeeded.

	 - Parameter progress: A fresh progress that the operation writes exclusively from now on, or `nil` if the caller doesn't observe progress. Must be split only once.
	 - Parameter pendingUnitCounts: The share of each phase, summing up to 999.
	 */
	static func phases(of progress: Progress?, _ pendingUnitCounts: Int64...) -> ProgressPhases {
		guard let progress else {
			return ProgressPhases(progress: nil, children: [])
		}
		assert(progress.completedUnitCount == 0, "expected a fresh progress, but completedUnitCount was \(progress.completedUnitCount)")
		assert(pendingUnitCounts.reduce(0, +) == phasesTotalUnitCount - 1, "expected the phases to share \(phasesTotalUnitCount - 1) units, but got \(pendingUnitCounts)")
		progress.completedUnitCount = 0
		progress.totalUnitCount = phasesTotalUnitCount
		return ProgressPhases(progress: progress, children: pendingUnitCounts.map { progress.makeExplicitChild(pendingUnitCount: $0) })
	}

	/// Creates a child of this progress only, whereas `Progress(totalUnitCount:)` attaches to the progress that is current on the calling thread.
	func makeExplicitChild(pendingUnitCount: Int64) -> Progress {
		return Progress(totalUnitCount: 1, parent: self, pendingUnitCount: pendingUnitCount)
	}
}

/// The explicit children that `Progress.phases(of:_:)` created for the phases of an operation.
struct ProgressPhases: Sendable {
	private let progress: Progress?
	private let children: [Progress]

	fileprivate init(progress: Progress?, children: [Progress]) {
		self.progress = progress
		self.children = children
	}

	/// The child of the phase at the given index, or `nil` if the caller doesn't observe progress.
	subscript(index: Int) -> Progress? {
		return progress == nil ? nil : children[index]
	}

	/// Completes all phases and the reserved final unit. Must only be called when the operation is about to return successfully.
	func completeTransfer() {
		guard let progress else {
			return
		}
		for child in children {
			if child.totalUnitCount <= 0 {
				child.totalUnitCount = 1
			}
			child.completedUnitCount = child.totalUnitCount
		}
		progress.completedUnitCount = progress.totalUnitCount
	}
}
