import MCP
import Foundation
import SwiftSoup

extension ToolCommand {
	static let fetchPage = ToolCommand(rawValue: "fetch-page")
}

/// Tool for fetching web page content using URLSession (no JavaScript rendering)
///
/// This tool fetches HTML content from a URL, strips HTML tags, and returns clean text.
/// For pages that require JavaScript rendering, use `render-page` instead.
///
/// Features:
/// - Simple HTTP(S) fetching via URLSession
/// - HTML parsing and text extraction
/// - Pagination support for large content
/// - Basic metadata extraction (title, content length)
struct FetchPageTool: ToolImplementation {
	static let command: ToolCommand = .fetchPage
	
	// JSON Schema reference: https://json-schema.org/understanding-json-schema/reference
	static let tool = Tool(
		name: command.rawValue,
		description: "Fetches web page content and returns cleaned text. Prefer this tool over the built-in fetch tool for web content reading and analysis. Can also search within the page. Does not execute JavaScript (render-page tool coming soon for JS-heavy sites).",
		inputSchema: .object([
			"type": "object",
			"properties": .object([
				"url": .object([
					"type": "string",
					"description": "The URL to fetch (must be http:// or https://)"
				]),
				"query": .object([
					"type": "string",
					"description": "Optional search query. When provided, searches the entire webpage and returns match positions with context. When omitted, returns paginated content."
				]),
				"offset": .object([
					"type": "integer",
					"description": "Starting character position for pagination (default: 0). Ignored when query is provided."
				]),
				"limit": .object([
					"type": "integer",
					"description": "Maximum number of characters to return (default: 10000). Ignored when query is provided."
				]),
				"includeMetadata": .object([
					"type": "boolean",
					"description": "Include page metadata like title and description (default: true)"
				])
			]),
			"required": .array([.string("url")])
		])
	)
	
	// Typed properties
	let url: URL
	let query: String?
	let offset: Int
	let limit: Int
	let includeMetadata: Bool
	
	/// Initialize and validate parameters
	init(arguments: CallTool.Parameters) throws(ContentError) {
		// Extract and validate URL
		guard let urlString = arguments.strings.url else {
			throw .missingArgument("url")
		}
		
		guard let url = URL(string: urlString),
			  let scheme = url.scheme,
			  ["http", "https"].contains(scheme) else {
			throw .contentError(message: "Invalid URL. Must be a valid http:// or https:// URL")
		}
		
		self.url = url
		self.query = arguments.strings.query
		self.offset = arguments.integers.offset ?? 0
		self.limit = arguments.integers.limit ?? 10000
		self.includeMetadata = arguments.bools.includeMetadata ?? true
		
		// Validate offset
		guard self.offset >= 0 else {
			throw .contentError(message: "offset must be >= 0")
		}
		
		// Validate limit
		guard self.limit > 0 && self.limit <= 500000 else {
			throw .contentError(message: "limit must be between 1 and 500000")
		}
	}
	
	/// Execute the tool
	func callAsFunction() async throws(ContentError) -> CallTool.Result {
		do {
			// Fetch the page
			let (data, response) = try await URLSession.shared.data(from: url)
			
			// Validate HTTP response
			guard let httpResponse = response as? HTTPURLResponse else {
				throw ContentError.contentError(message: "Invalid response from server")
			}
			
			guard (200...299).contains(httpResponse.statusCode) else {
				throw ContentError.contentError(message: "HTTP \(httpResponse.statusCode): Failed to fetch page")
			}
			
			// Convert to string
			guard let html = String(data: data, encoding: .utf8) else {
				throw ContentError.contentError(message: "Failed to decode HTML content")
			}
			
			// Parse HTML
			let document = try SwiftSoup.parse(html)
			
			// Extract text content (removes all HTML tags, scripts, styles)
			let fullText = try document.text()
			let totalLength = fullText.count
			
			// Extract metadata if requested
			let title: String? = includeMetadata ? (try? document.title()) : nil
			let description: String? = includeMetadata ? (try? document.select("meta[name=description]").first()?.attr("content")) : nil
			
			// Check if we're in search mode or fetch mode
			if let searchQuery = query, !searchQuery.isEmpty {
				// Search mode: find all occurrences and return match positions with context
				return try performSearch(
					query: searchQuery,
					fullText: fullText,
					title: title,
					description: description,
					totalLength: totalLength
				)
			} else {
				// Fetch mode: return paginated content
				return try performFetch(
					fullText: fullText,
					title: title,
					description: description,
					totalLength: totalLength
				)
			}
			
		} catch let error as ContentError {
			throw error
		} catch {
			throw ContentError.other(error)
		}
	}
	
	// MARK: - Search Mode
	
	private func performSearch(
		query: String,
		fullText: String,
		title: String?,
		description: String?,
		totalLength: Int
	) throws(ContentError) -> CallTool.Result {
		struct SearchMatch: Codable, Sendable {
			let position: Int
			let context: String
		}
		
		struct SearchResult: Codable, Sendable {
			let query: String
			let matches: [SearchMatch]
			let totalMatches: Int
			let title: String?
			let description: String?
			let url: String
			let webpageLength: Int
		}
		
		var matches: [SearchMatch] = []
		let contextRadius = 100 // Characters before/after match to include
		
		// Case-insensitive search
		let lowercasedText = fullText.lowercased()
		let lowercasedQuery = query.lowercased()
		
		var searchRange = lowercasedText.startIndex..<lowercasedText.endIndex
		
		while let range = lowercasedText.range(of: lowercasedQuery, range: searchRange) {
			let position = lowercasedText.distance(from: lowercasedText.startIndex, to: range.lowerBound)
			
			// Calculate context window
			let contextStart = fullText.index(
				range.lowerBound,
				offsetBy: -contextRadius,
				limitedBy: fullText.startIndex
			) ?? fullText.startIndex
			
			let contextEnd = fullText.index(
				range.upperBound,
				offsetBy: contextRadius,
				limitedBy: fullText.endIndex
			) ?? fullText.endIndex
			
			let contextText = String(fullText[contextStart..<contextEnd])
			let prefix = contextStart != fullText.startIndex ? "..." : ""
			let suffix = contextEnd != fullText.endIndex ? "..." : ""
			
			matches.append(SearchMatch(
				position: position,
				context: "\(prefix)\(contextText)\(suffix)"
			))
			
			// Move search range past this match
			searchRange = range.upperBound..<lowercasedText.endIndex
		}
		
		let searchResult = SearchResult(
			query: query,
			matches: matches,
			totalMatches: matches.count,
			title: title,
			description: description,
			url: url.absoluteString,
			webpageLength: totalLength
		)
		
		let output = StructuredContentOutput(
			inputRequest: "fetch-page: \(url.absoluteString) (search: \"\(query)\")",
			metaData: nil,
			content: [searchResult]
		)
		
		return output.toResult()
	}
	
	// MARK: - Fetch Mode
	
	private func performFetch(
		fullText: String,
		title: String?,
		description: String?,
		totalLength: Int
	) throws(ContentError) -> CallTool.Result {
		// Apply pagination
		let startIndex = fullText.index(fullText.startIndex, offsetBy: min(offset, totalLength), limitedBy: fullText.endIndex) ?? fullText.endIndex
		let endOffset = min(offset + limit, totalLength)
		let endIndex = fullText.index(fullText.startIndex, offsetBy: endOffset, limitedBy: fullText.endIndex) ?? fullText.endIndex
		
		let contentSlice = String(fullText[startIndex..<endIndex])
		let hasMore = endOffset < totalLength
		
		struct PageContent: Codable, Sendable {
			let text: String
			let title: String?
			let description: String?
			let url: String
			let contentLength: Int
			let returnedLength: Int
			let offset: Int
			let hasMore: Bool
			let nextOffset: Int?
		}
		
		let pageContent = PageContent(
			text: contentSlice,
			title: title,
			description: description,
			url: url.absoluteString,
			contentLength: totalLength,
			returnedLength: contentSlice.count,
			offset: offset,
			hasMore: hasMore,
			nextOffset: hasMore ? endOffset : nil
		)
		
		let output = StructuredContentOutput(
			inputRequest: "fetch-page: \(url.absoluteString) (offset: \(offset), limit: \(limit))",
			metaData: nil,
			content: [pageContent]
		)
		
		return output.toResult()
	}
}