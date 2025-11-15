import Foundation

struct FetchStatistics: Codable, Sendable, Hashable {
	let retrievalTime: TimeInterval
	let cacheHit: Bool
	let cacheAge: TimeInterval?
	let cacheTTL: TimeInterval?
	let searchTime: TimeInterval?
}
