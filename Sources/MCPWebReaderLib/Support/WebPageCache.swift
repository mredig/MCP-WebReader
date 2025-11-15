import CryptoKit
import Foundation
import SwiftPizzaSnips

/// Helper for caching fetched webpage content
actor WebPageCache {
//	static let shared = WebPageCache()
	
	private let cacheDirectory: URL
	private let cacheDuration: TimeInterval = 3600 // 1 hour
	
	init() {
		// Get system cache directory
		let cacheDir = URL
			.cachesDirectory
			.appendingPathComponent("com.webreader.mcp", conformingTo: .folder)

		self.cacheDirectory = cacheDir
		
		// Create cache directory if it doesn't exist
		try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
	}
	
	/// Fetch URL with caching support
	func fetch(url: URL) async throws -> (Data, URLResponse) {
		let cacheURL = cacheFileURL(for: url)
		let metadataURL = cacheURL.appendingPathExtension("meta")
		
		// Check if cached version exists and is fresh
		do {
			return try loadCachedData(cacheURL: cacheURL, metadataURL: metadataURL)
		} catch {
			switch error {
			case .cacheMiss:
				break
			case .other(let error):
				print("Error loading cached object: \(error)")
			}
		}

		// Cache miss or stale - fetch fresh data
		let (data, response) = try await URLSession.shared.data(from: url)
		
		// Cache the result if successful
		if let httpResponse = response as? HTTPURLResponse,
		   (200...299).contains(httpResponse.statusCode) {
			try saveToCache(data: data, url: url, contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"))
		}
		
		return (data, response)
	}
	
	/// Load cached data if available and fresh
	private func loadCachedData(cacheURL: URL, metadataURL: URL) throws(CacheLoadError) -> (Data, URLResponse) {
		let fileManager = FileManager.default
		
		guard
			cacheURL.checkResourceIsAccessible(),
			metadataURL.checkResourceIsAccessible()
		else { throw .cacheMiss }

		do {
			let cacheData = try Data(contentsOf: cacheURL)
			let metadataData = try Data(contentsOf: metadataURL)
			let metadata = try JSONDecoder().decode(CacheMetadata.self, from: metadataData)

			// Check if cache is still fresh
			guard Date().timeIntervalSince(metadata.timestamp) < cacheDuration else {
				throw CacheLoadError.cacheMiss
			}

			// Return cached data with synthetic response
			let response = HTTPURLResponse(
				url: URL(string: metadata.url)!,
				statusCode: 200,
				httpVersion: "HTTP/1.1",
				headerFields: ["Content-Type": metadata.contentType]
			)!

			return (cacheData, response)
		} catch let error as CacheLoadError {
			throw error
		} catch {
			throw .other(error)
		}
	}

	enum CacheLoadError: Error {
		case cacheMiss
		case other(Error)
	}

	/// Save data to cache
	private func saveToCache(data: Data, url: URL, contentType: String?) throws {
		let cacheURL = cacheFileURL(for: url)
		let metadataURL = cacheURL.appendingPathExtension("meta")
		
		// Write data
		try data.write(to: cacheURL, options: .atomic)
		
		// Write metadata
		let metadata = CacheMetadata(
			url: url.absoluteString,
			timestamp: Date(),
			contentType: contentType ?? "text/html"
		)
		
		let metadataData = try JSONEncoder().encode(metadata)
		try metadataData.write(to: metadataURL, options: .atomic)
	}
	
	/// Get cache file URL for a given webpage URL
	private func cacheFileURL(for url: URL) -> URL {
		// Generate filename from URL hash
		let urlString = url.absoluteString
		let hash = SHA256.hash(data: Data(urlString.utf8))
		let hashString = hash.compactMap { String(format: "%02x", $0) }.joined()
		
		return cacheDirectory.appendingPathComponent(hashString)
	}
	
	/// Clear all cached content
	func clearCache() throws {
		let fileManager = FileManager.default
		if fileManager.fileExists(atPath: cacheDirectory.path) {
			try fileManager.removeItem(at: cacheDirectory)
			try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
		}
	}
	
	// MARK: - Cache Metadata
	
	private struct CacheMetadata: Codable {
		let url: String
		let timestamp: Date
		let contentType: String
	}
}
