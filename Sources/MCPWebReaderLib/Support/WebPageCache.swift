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
	func fetch(url: URL, ignoreCache: Bool) async throws -> CacheResponse {
		let cacheURL = cacheFileURL(for: url)
		let metadataURL = cacheURL.appendingPathExtension("meta")
		
		// Check if cached version exists and is fresh
		if ignoreCache == false {
			do {
				return try await loadCachedData(cacheURL: cacheURL, metadataURL: metadataURL)
			} catch {
				switch error {
				case .cacheMiss:
					break
				case .other(let error):
					print("Error loading cached object: \(error)")
				}
			}
		}

		// Cache miss or stale - fetch fresh data
		let (data, response) = try await URLSession.shared.data(from: url)
		
		// Cache the result if successful
		if let httpResponse = response as? HTTPURLResponse,
		   (200...299).contains(httpResponse.statusCode) {
			try saveToCache(data: data, url: url, contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"))
		}
		
		return CacheResponse(
			data: data,
			response: response,
			cacheHit: false,
			cacheAge: nil,
			cacheTTL: cacheDuration)
	}

	/// Load cached data if available and fresh
	private func loadCachedData(cacheURL: URL, metadataURL: URL) async throws(CacheLoadError) -> CacheResponse {
		guard
			cacheURL.checkResourceIsAccessible(),
			metadataURL.checkResourceIsAccessible()
		else { throw .cacheMiss }

		do {
			let modificationDate = (try? cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
			async let cacheData = Data(contentsOf: cacheURL)
			let metadataData = try Data(contentsOf: metadataURL)
			async let metadata = JSONDecoder().decode(CacheMetadata.self, from: metadataData)

			// Check if cache is still fresh
			let cacheAge = Date.now.timeIntervalSince(modificationDate)
			guard cacheAge < cacheDuration else {
				throw CacheLoadError.cacheMiss
			}

			// Return cached data with synthetic response
			let response = try await HTTPURLResponse(
				url: URL(string: metadata.url)!,
				statusCode: 200,
				httpVersion: "HTTP/1.1",
				headerFields: ["Content-Type": metadata.contentType]
			)!

			// Don't clean up every time - do it 10% of the time.
			if Int.random(in: 0..<100) > 90 {
				await cleanupCache()
			}

			return try await CacheResponse(
				data: cacheData,
				response: response,
				cacheHit: true,
				cacheAge: cacheAge,
				cacheTTL: cacheDuration - cacheAge)
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

	private func cleanupCache() async {
		let contents = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []

		let expired = contents.filter {
			let modDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now

			return Date.now.timeIntervalSince(modDate) > cacheDuration
		}

		for expiredCacheItem in expired {
			try? FileManager.default.removeItem(at: expiredCacheItem)
		}
	}

	// MARK: - Cache Metadata
	
	private struct CacheMetadata: Codable {
		let url: String
		let timestamp: Date
		let contentType: String
	}

	struct CacheResponse: Sendable {
		let data: Data
		let response: URLResponse

		let cacheHit: Bool
		let cacheAge: TimeInterval?
		let cacheTTL: TimeInterval?
	}
}
