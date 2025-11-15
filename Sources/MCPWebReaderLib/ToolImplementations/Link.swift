import Foundation

/// Represents a link found on a webpage
struct Link: Codable, Sendable {
	let text: String
	let url: URL
	let contextBefore: String?
	let contextAfter: String?

	var totalContext: String {
		[
			contextBefore,
			text,
			contextAfter
		]
			.compactMap(\.self)
			.joined(separator: " ")
	}
}
