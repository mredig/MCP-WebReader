import MCP
import Foundation
import SwiftSoup

extension ToolCommand {
	static let searchWeb = ToolCommand(rawValue: "search-web")
}

/// Tool for searching the web using various search engines
///
/// This tool constructs a search URL for a given search engine and query, fetches the results page,
/// and extracts links with their context. It's a wrapper around search-page that makes web searching
/// more convenient by handling search engine URL construction.
///
/// Features:
/// - Multiple search engine support (Google, DuckDuckGo, Bing, Brave)
/// - Custom search engine support via URL template
/// - Smart renderJS defaults per engine
/// - Returns links with context (not full page content)
/// - Shares cache with other tools for efficiency
struct SearchWebTool: ToolImplementation {
	static let command: ToolCommand = .searchWeb
	
	static let tool = Tool(
		name: command.rawValue,
		description: "Search the web using a search engine (Google, DuckDuckGo, Bing, Brave) or a custom search URL template. Returns links with context from search results. Works symbiotically with other tools: use search-web to discover relevant URLs, then use fetch-page to read content from those URLs or search-page to search within them. Uses caching for efficiency.",
		inputSchema: .object([
			"type": "object",
			"properties": .object([
				"query": .object([
					"type": "string",
					"description": "Search query to look for on the web"
				]),
				"engine": .object([
					"type": "string",
					"description": "Search engine to use (default: duckduckgo-lite). If `custom` is specified, `customSearchURL` must be populated.",
					"enum": .array(SearchEngine.allCases.map { .string($0.name) })
				]),
				"customSearchURL": .object([
					"type": "string",
					"description": "Custom search URL template (optional if engine contains URL template). Use {{{SEARCH_QUERY}}} as placeholder for the search query. Example: https://www.startpage.com/do/search?q={{{SEARCH_QUERY}}}"
				]),
				"renderJS": .object([
					"type": "boolean",
					"description": "Whether to render JavaScript before extracting results. If omitted, uses intelligent default based on selected engine."
				]),
				"httpMethod": .object([
					"type": "string",
					"description": "HTTP method to use (default: GET)"
				]),
				"userAgent": .object([
					"type": "string",
					"description": "Custom User-Agent header. If omitted, uses system default."
				]),
				"customHeaders": .object([
					"type": "object",
					"description": "Custom HTTP headers as key-value pairs"
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
			"required": .array([.string("query")])
		])
	)
	
	enum SearchEngine: CaseIterable {
		case google
		case duckDuckGo
		case duckDuckGoLite
		case duckDuckGoHTML
		case bing
		case brave
		case custom(String)

		/// Technically violates the contract in that it doesn't contain `custom`
		static var allCases: [SearchWebTool.SearchEngine] {
			[.google, .duckDuckGo, .duckDuckGoHTML, .duckDuckGoLite, .bing, .brave]
		}

		/// Initialize from a string - either a known engine name or a custom template URL
		/// - Parameter string: Engine name ("google", "duckduckgo", etc.) or custom URL template containing {{{SEARCH_QUERY}}}
		/// - Returns: SearchEngine case if valid, nil otherwise
		init?(from string: String) {
			switch string.lowercased() {
			case Self.google.name:
				self = .google
			case Self.duckDuckGo.name:
				self = .duckDuckGo
			case Self.duckDuckGoLite.name:
				self = .duckDuckGoLite
			case Self.duckDuckGoHTML.name:
				self = .duckDuckGoHTML
			case Self.bing.name:
				self = .bing
			case Self.brave.name:
				self = .brave
			default:
				// Check if it's a custom template
				if string.contains("{{{SEARCH_QUERY}}}") {
					self = .custom(string)
				} else {
					return nil
				}
			}
		}
		
		var urlTemplate: String {
			switch self {
			case .google:
				return "https://www.google.com/search?q={{{SEARCH_QUERY}}}"
			case .duckDuckGo:
				return "https://duckduckgo.com/?q={{{SEARCH_QUERY}}}"
			case .duckDuckGoHTML:
				return "https://duckduckgo.com/html/?q={{{SEARCH_QUERY}}}"
			case .duckDuckGoLite:
				return "https://duckduckgo.com/lite/?q={{{SEARCH_QUERY}}}"
			case .bing:
				return "https://www.bing.com/search?q={{{SEARCH_QUERY}}}"
			case .brave:
				return "https://search.brave.com/search?q={{{SEARCH_QUERY}}}"
			case .custom(let template):
				return template
			}
		}
		
		var defaultRenderJS: Bool {
			switch self {
			case .google, .bing, .duckDuckGo:
				return true
			case .duckDuckGoLite, .duckDuckGoHTML, .brave, .custom:
				return false
			}
		}
		
		var name: String {
			switch self {
			case .google: "google"
			case .duckDuckGo: "duckduckgo"
			case .duckDuckGoHTML: "duckduckgo-html"
			case .duckDuckGoLite: "duckduckgo-lite"
			case .bing: "bing"
			case .brave: "brave"
			case .custom: "custom"
			}
		}
	}
	
	// Typed properties
	let query: String
	let engine: SearchEngine
	let renderJS: Bool
	let httpMethod: String
	let userAgent: String?
	let customHeaders: [String: String]
	let ignoreCache: Bool
	let includeMetadata: Bool
	
	private let webEngine: WebPageEngine
	
	/// Initialize and validate parameters
	init(arguments: CallTool.Parameters, engine: WebPageEngine) throws(ContentError) {
		self.webEngine = engine
		
		// Extract and validate query
		guard let query = arguments.strings.query, !query.isEmpty else {
			throw .missingArgument("query")
		}
		self.query = query

		// Extract search engine - customSearchURL required if engine is "custom"
		let engineString = arguments.strings.engine ?? "duckduckgo-lite"
		let searchEngine: SearchEngine
		if engineString == "custom" {
			guard
				let customURL = arguments.strings.customSearchURL,
				URL(string: customURL) != nil,
				let engine = SearchEngine(from: customURL)
			else {
				throw .contentError(message: "customSearchURL must contain {{{SEARCH_QUERY}}} placeholder")
			}
			searchEngine = engine
		} else {
			guard let engine = SearchEngine(from: engineString) else {
				throw .contentError(message: "Invalid engine: \(engineString). Must be one of: google, duckduckgo, bing, brave, or a custom URL template with {{{SEARCH_QUERY}}}")
			}
			searchEngine = engine
		}
		
		self.engine = searchEngine
		
		// Use intelligent default for renderJS based on engine, or explicit value if provided
		self.renderJS = arguments.bools.renderJS ?? searchEngine.defaultRenderJS
		
		self.httpMethod = arguments.strings.httpMethod ?? "GET"
		self.userAgent = arguments.strings.userAgent
		self.ignoreCache = arguments.bools.ignoreCache ?? false
		self.includeMetadata = arguments.bools.includeMetadata ?? true
		
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
			// Construct search URL
			let urlTemplate = engine.urlTemplate
			let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
			let urlString = urlTemplate.replacingOccurrences(of: "{{{SEARCH_QUERY}}}", with: encodedQuery)
			
			guard let url = URL(string: urlString) else {
				throw ContentError.contentError(message: "Failed to construct valid search URL")
			}
			
			let startTime = Date()
			
			// Fetch the search results page (with caching)
			let cacheResponse = try await webEngine.fetch(
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
				throw ContentError.contentError(message: "HTTP \(httpResponse.statusCode): Failed to fetch search results")
			}
			
			// Convert to string
			guard let html = String(data: data, encoding: .utf8) else {
				throw ContentError.contentError(message: "Failed to decode HTML content")
			}
			
			let parseTimeStart = Date()
			// Parse HTML
			let document = try SwiftSoup.parse(html)
			
			// Extract links (always enabled for search results)
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
					
					// Don't filter by same-site for search results - we want external links
					
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
			
			// Return search results (links only, no full page content)
			return try buildSearchResults(
				url: url,
				title: title,
				description: description,
				links: links,
				statsForward: statsForward)
		} catch let error as ContentError {
			throw error
		} catch {
			throw ContentError.other(error)
		}
	}
	
	// MARK: - Results Building
	
	private func buildSearchResults(
		url: URL,
		title: String?,
		description: String?,
		links: [Link],
		statsForward: StatsForward
	) throws(ContentError) -> CallTool.Result {
		struct SearchWebResult: Codable, Sendable {
			let query: String
			let searchEngine: String
			let searchURL: String
			let title: String?
			let description: String?
			let links: [Link]
			let linkCount: Int
			let statistics: FetchStatistics
		}
		
		let result = SearchWebResult(
			query: query,
			searchEngine: engine.name,
			searchURL: url.absoluteString,
			title: title,
			description: description,
			links: links,
			linkCount: links.count,
			statistics: FetchStatistics(
				totalTime: Date.now.timeIntervalSince(statsForward.startTime),
				networkTime: statsForward.networkFetchTime,
				parsingTime: statsForward.parseTime,
				cacheHit: statsForward.cacheHit,
				cacheAge: statsForward.cacheAge,
				cacheTTL: statsForward.cacheTTL,
				searchTime: nil))
		
		let output = StructuredContentOutput(
			inputRequest: "search-web: \"\(query)\" (engine: \(engine.name))",
			metaData: nil,
			content: [result]
		)
		
		return output.toResult()
	}
}
