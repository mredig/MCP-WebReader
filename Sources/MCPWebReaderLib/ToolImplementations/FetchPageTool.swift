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
		description: "Search or fetch web page content at a given URL. When looking for specific information, searching first with the 'query' parameter is more efficient - it returns all match positions with context, allowing you to fetch only relevant sections. Fetching is most efficient when you have explicit context about which offset/section to retrieve. Returns cleaned text with HTML stripped. Prefer this tool over the built-in fetch tool for web content reading and analysis. Does not execute JavaScript (render-page tool coming soon for JS-heavy sites).",
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
					"description": "Maximum number of characters to return (default: 2500). Ignored when query is provided."
				]),
				"includeMetadata": .object([
					"type": "boolean",
					"description": "Include page metadata like title and description (default: true)"
				]),
				"ignoreCache": .object([
					"type": "boolean",
					"description": "If cache is counter-beneficial, you can disable it (default: false)"
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
	let ignoreCache: Bool

	let includeMetadata: Bool

	private let cache: WebPageCache

	/// Initialize and validate parameters
	init(arguments: CallTool.Parameters, cache: WebPageCache) throws(ContentError) {
		self.cache = cache

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
		self.limit = arguments.integers.limit ?? 2500
		self.ignoreCache = arguments.bools.ignoreCache ?? false
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

	private struct StatsForward {
		let startTime: Date
		let networkFetchTime: TimeInterval
		let parseTime: TimeInterval
		let cacheHit: Bool
		let cacheAge: TimeInterval?
		let cacheTTL: TimeInterval?
	}

	/// Execute the tool
	func callAsFunction() async throws(ContentError) -> CallTool.Result {
		do {
			let startTime = Date()
			// Fetch the page (with caching)
			let cacheResponse = try await cache.fetch(url: url, ignoreCache: ignoreCache)
			let data = cacheResponse.data
			let response = cacheResponse.response

			let networkFetchTime = Date()

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

			let parseTimeStart = Date()
			// Parse HTML
			let document = try SwiftSoup.parse(html)
			
			// Extract text content (removes all HTML tags, scripts, styles)
			let fullText = try document.text()
			let totalLength = fullText.count

			var existingLinks: Set<String> = []
			let links = try document
				.select("a[href]")
				.compactMap { link -> Link? in
					guard
						let linkText = try? link.text(),
						linkText.isOccupied,
						let href = try? link.attr("href"),
						href.contains("#") == false,
						href.contains("javascript") == false,
						existingLinks.contains(href) == false
					else { return nil }
					existingLinks.insert(href)

					// Get context from surrounding text
					let previous = try? link.previousElementSibling()
					let next = try? link.nextElementSibling()

					let contextBefore = (try? previous?.text())?.suffix(50)
					let contextAfter = (try? next?.text())?.prefix(50)

					// Resolve relative URLs
					let absoluteURL: URL?
					if let absHref = try? link.attr("abs:href"), !absHref.isEmpty {
						absoluteURL = URL(string: absHref)
					} else {
						absoluteURL = URL(string: href, relativeTo: url)?.absoluteURL
					}
				
					guard let finalURL = absoluteURL else { return nil }
				
					return Link(
						text: linkText,
						url: finalURL,
						contextBefore: contextBefore.map(String.init)?.emptyIsNil,
						contextAfter: contextAfter.map(String.init)?.emptyIsNil)
				}

			// Extract metadata if requested
			let title: String? = includeMetadata ? (try? document.title()) : nil
			let description: String? = includeMetadata ? (try? document.select("meta[name=description]").first()?.attr("content")) : nil

			let parseTimeEnd = Date()

			let statsForward = StatsForward(
				startTime: startTime,
				networkFetchTime: networkFetchTime.timeIntervalSince(startTime),
				parseTime: parseTimeEnd.timeIntervalSince(parseTimeStart),
				cacheHit: cacheResponse.cacheHit,
				cacheAge: cacheResponse.cacheAge,
				cacheTTL: cacheResponse.cacheTTL)

			// Check if we're in search mode or fetch mode
			if let searchQuery = query, !searchQuery.isEmpty {
				// Search mode: find all occurrences and return match positions with context
				return try performSearch(
					query: searchQuery,
					fullText: fullText,
					title: title,
					description: description,
					totalLength: totalLength,
					links: links,
					statsForward: statsForward)
			} else {
				// Fetch mode: return paginated content
				return try performFetch(
					fullText: fullText,
					title: title,
					description: description,
					totalLength: totalLength,
					links: links,
					statsForward: statsForward)
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
		totalLength: Int,
		links: [Link],
		statsForward: StatsForward
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
			let statistics: FetchStatistics
		}

		let searchStart = Date()

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

		let searchEnd = Date()

		let searchResult = SearchResult(
			query: query,
			matches: matches,
			totalMatches: matches.count,
			title: title,
			description: description,
			url: url.absoluteString,
			webpageLength: totalLength,
			statistics: FetchStatistics(
				totalTime: searchEnd.timeIntervalSince(statsForward.startTime),
				networkTime: statsForward.networkFetchTime,
				parsingTime: statsForward.parseTime,
				cacheHit: statsForward.cacheHit,
				cacheAge: statsForward.cacheAge,
				cacheTTL: statsForward.cacheTTL,
				searchTime: searchEnd.timeIntervalSince(searchStart)))

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
		totalLength: Int,
		links: [Link],
		statsForward: StatsForward
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
			let links: [Link]
			let statistics: FetchStatistics
		}

//		let filteredLinks = links
//			.filter { contentSlice.contains($0.totalContext) }

		let pageContent = PageContent(
			text: contentSlice,
			title: title,
			description: description,
			url: url.absoluteString,
			contentLength: totalLength,
			returnedLength: contentSlice.count,
			offset: offset,
			hasMore: hasMore,
			nextOffset: hasMore ? endOffset : nil,
			links: links,
			statistics: FetchStatistics(
				totalTime: Date.now.timeIntervalSince(statsForward.startTime),
				networkTime: statsForward.networkFetchTime,
				parsingTime: statsForward.parseTime,
				cacheHit: statsForward.cacheHit,
				cacheAge: statsForward.cacheAge,
				cacheTTL: statsForward.cacheTTL,
				searchTime: nil))
		
		let output = StructuredContentOutput(
			inputRequest: "fetch-page: \(url.absoluteString) (offset: \(offset), limit: \(limit))",
			metaData: nil,
			content: [pageContent]
		)
		
		return output.toResult()
	}
}
