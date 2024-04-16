import Foundation
import Promises

extension Promise {
	func async() async throws -> Value {
		try await withCheckedThrowingContinuation { continuation in
			then { value in
				continuation.resume(returning: value)
			}.catch { error in
				continuation.resume(throwing: error)
			}
		}
	}
}
