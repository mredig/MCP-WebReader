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
		description: "Fetches web page content and returns cleaned text. Does not execute JavaScript - use render-page for JS-heavy sites.",
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
					"description": "Maximum number of characters to return (default: 10000)"
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
			
			// Apply pagination
			let startIndex = fullText.index(fullText.startIndex, offsetBy: min(offset, totalLength), limitedBy: fullText.endIndex) ?? fullText.endIndex
			let endOffset = min(offset + limit, totalLength)
			let endIndex = fullText.index(fullText.startIndex, offsetBy: endOffset, limitedBy: fullText.endIndex) ?? fullText.endIndex
			
			let contentSlice = String(fullText[startIndex..<endIndex])
			let hasMore = endOffset < totalLength
			
			// Build response with proper Codable types
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
			
			// Extract metadata if requested
			let title: String? = includeMetadata ? (try? document.title()) : nil
			let description: String? = includeMetadata ? (try? document.select("meta[name=description]").first()?.attr("content")) : nil
			
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
			
		} catch let error as ContentError {
			throw error
		} catch {
			throw ContentError.other(error)
		}
	}
}