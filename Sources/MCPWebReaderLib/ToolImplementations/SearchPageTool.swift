import MCP
import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ToolCommand {
	static let searchPage = ToolCommand(rawValue: "search-page")
}

/// Tool for searching within a web page
///
/// This tool fetches a webpage (with caching support) and searches for all occurrences of a query string,
/// returning match positions with surrounding context. Works symbiotically with fetch-page - use this to
/// find relevant sections, then use fetch-page with specific offsets to retrieve full content.
///
/// Features:
/// - Case-insensitive search
/// - Returns character positions for each match
/// - Provides context around each match
/// - Shares cache with fetch-page for efficiency
/// - Supports JavaScript rendering for dynamic content
struct SearchPageTool: ToolImplementation {
	static let command: ToolCommand = .searchPage

	static let tool = Tool(
		name: command.rawValue,
		description: "Search for text within a web page and return all match positions with context. Use this to find specific information on a page, then use fetch-page with the returned positions to retrieve full content. Shares cache with fetch-page for efficiency. Use `renderJS: true` for JavaScript-heavy sites.",
		inputSchema: .object([
			"type": "object",
			"properties": .object([
				"url": .object([
					"type": "string",
					"description": "The URL to search (must be http:// or https://)"
				]),
				"query": .object([
					"type": "string",
					"description": "Search query to find within the page. Case-insensitive."
				]),
				"renderJS": .object([
					"type": "boolean",
					"description": "Whether to render JavaScript before searching (default: false). Use true for modern SPAs and JS-heavy sites."
				]),
				"httpMethod": .object([
					"type": "string",
					"description": "HTTP method to use (default: GET). Can be GET, POST, PUT, DELETE, PATCH, HEAD, etc."
				]),
				"userAgent": .object([
					"type": "string",
					"description": "Custom User-Agent header. If omitted, uses system default."
				]),
				"customHeaders": .object([
					"type": "object",
					"description": "Custom HTTP headers as key-value pairs. Note: certain headers like Host may be silently filtered."
				]),
				"includeMetadata": .object([
					"type": "boolean",
					"description": "Include page metadata like title and description (default: true)"
				]),
				"includeLinks": .object([
					"type": "boolean",
					"description": "Include links found on the page (default: false)"
				]),
				"sameSiteLinksOnly": .object([
					"type": "boolean",
					"description": "When including links, only return links to the same site (default: true). Ignored if includeLinks is false."
				]),
				"ignoreCache": .object([
					"type": "boolean",
					"description": "If cache is counter-beneficial, you can disable it (default: false)"
				])
			]),
			"required": .array([.string("url"), .string("query")])
		])
	)

	// Typed properties
	let url: URL
	let query: String
	let renderJS: Bool
	let httpMethod: String
	let userAgent: String?
	let customHeaders: [String: String]
	let ignoreCache: Bool
	let includeMetadata: Bool
	let includeLinks: Bool
	let sameSiteLinksOnly: Bool

	private let engine: WebPageEngine

	/// Initialize and validate parameters
	init(arguments: CallTool.Parameters, engine: WebPageEngine) throws(ContentError) {
		self.engine = engine

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

		// Extract and validate query
		guard let query = arguments.strings.query, !query.isEmpty else {
			throw .missingArgument("query")
		}

		self.query = query
		self.renderJS = arguments.bools.renderJS ?? false
		self.httpMethod = arguments.strings.httpMethod ?? "GET"
		self.userAgent = arguments.strings.userAgent
		self.ignoreCache = arguments.bools.ignoreCache ?? false
		self.includeMetadata = arguments.bools.includeMetadata ?? true
		self.includeLinks = arguments.bools.includeLinks ?? false
		self.sameSiteLinksOnly = arguments.bools.sameSiteLinksOnly ?? true

		// Extract custom headers if provided
		if let headersDict = arguments.arguments?["customHeaders"]?.objectValue {
			var headers: [String: String] = [:]
			for (key, value) in headersDict {
				guard let stringValue = value.stringValue else { continue }
				headers[key] = stringValue
			}
			self.customHeaders = headers
		} else {
			self.customHeaders = [:]
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
			let cacheResponse = try await engine.fetch(
				url: url,
				renderJS: renderJS,
				ignoreCache: ignoreCache,
				httpMethod: httpMethod,
				userAgent: userAgent,
				customHeaders: customHeaders
			)
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

			// Extract text content
			let fullText = try document.text()
			let totalLength = fullText.count

			// Extract links if requested
			let links: [Link]
			if includeLinks {
				var existingLinks: Set<String> = []
				links = try document
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

						// Filter by same-site if requested
						if sameSiteLinksOnly {
							guard finalURL.host == url.host else { return nil }
						}

						return Link(
							text: linkText,
							url: finalURL,
							contextBefore: contextBefore.map(String.init)?.emptyIsNil,
							contextAfter: contextAfter.map(String.init)?.emptyIsNil)
					}
			} else {
				links = []
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

			// Perform search
			return try performSearch(
				fullText: fullText,
				title: title,
				description: description,
				totalLength: totalLength,
				links: links,
				statsForward: statsForward)
		} catch let error as ContentError {
			throw error
		} catch {
			throw ContentError.other(error)
		}
	}

	// MARK: - Search Implementation

	private func performSearch(
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
			let links: [Link]
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
			links: links,
			statistics: FetchStatistics(
				totalTime: searchEnd.timeIntervalSince(statsForward.startTime),
				networkTime: statsForward.networkFetchTime,
				parsingTime: statsForward.parseTime,
				cacheHit: statsForward.cacheHit,
				cacheAge: statsForward.cacheAge,
				cacheTTL: statsForward.cacheTTL,
				searchTime: searchEnd.timeIntervalSince(searchStart)))

		let output = StructuredContentOutput(
			inputRequest: "search-page: \(url.absoluteString) (query: \"\(query)\")",
			metaData: nil,
			content: [searchResult]
		)

		return output.toResult()
	}
}
