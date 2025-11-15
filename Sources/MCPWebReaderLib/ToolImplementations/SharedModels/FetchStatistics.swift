import Foundation

struct FetchStatistics: Codable, Sendable, Hashable {
	let totalTime: TimeInterval
	let networkTime: TimeInterval
	let parsingTime: TimeInterval
	let cacheHit: Bool
	let cacheAge: TimeInterval?
	let cacheTTL: TimeInterval?
	let searchTime: TimeInterval?
}
