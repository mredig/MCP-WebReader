import MCP
import Foundation
import SwiftSoup
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension ToolCommand {
	static let fetchPage = ToolCommand(rawValue: "fetch-page")
}

/// Tool for fetching web page content with optional JavaScript rendering
///
/// This tool fetches HTML content from a URL, strips HTML tags, and returns clean text.
/// Set `renderJS: true` for pages that require JavaScript rendering (like modern SPAs, Google Search, Reddit).
/// Set `renderJS: false` (default) for simple HTTP fetching which is faster and more efficient.
///
/// Features:
/// - HTTP(S) fetching via URLSession or WKWebView (with JS rendering)
/// - HTML parsing and text extraction
/// - Pagination support for large content
/// - Link extraction with context
/// - Custom HTTP methods and headers
/// - Caching for performance
struct FetchPageTool: ToolImplementation {
	static let command: ToolCommand = .fetchPage

	// JSON Schema reference: https://json-schema.org/understanding-json-schema/reference
	static let tool = Tool(
		name: command.rawValue,
		description: "Fetch web page content at a given URL and return paginated text. Use `renderJS: true` for JavaScript-heavy sites (SPAs, Google Search, Reddit). Use `renderJS: false` (default) for faster fetching of static content. Returns cleaned text with HTML stripped. Works symbiotically with search-page: use search-page to find specific content and get character positions, then use fetch-page with offset/limit parameters to retrieve the full context around those positions. Can also be used with search-web results to read content from discovered URLs.",
		inputSchema: .object([
			"type": "object",
			"properties": .object([
				"url": .object([
					"type": "string",
					"description": "The URL to fetch (must be http:// or https://)"
				]),
				"offset": .object([
					"type": "integer",
					"description": "Starting character position for pagination (default: 0)"
				]),
				"limit": .object([
					"type": "integer",
					"description": "Maximum number of characters to return (default: 2500)"
				]),
				"renderJS": .object([
					"type": "boolean",
					"description": "Whether to render JavaScript before extracting content (default: false). Use true for modern SPAs and JS-heavy sites."
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
			"required": .array([.string("url")])
		])
	)

	// Typed properties
	let url: URL
	let offset: Int
	let limit: Int
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
		self.offset = arguments.integers.offset ?? 0
		self.limit = arguments.integers.limit ?? 2500
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

			// Extract text content (removes all HTML tags, scripts, styles)
			let fullText = try document.text()
			let totalLength = fullText.count

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

			// Return paginated content
			return try performFetch(
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
