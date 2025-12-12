#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import SwiftPizzaSnips
#if canImport(WebKit)
import WebKit
#endif
#if canImport(FoundationNetworking)
import WebReaderLinuxCompat
import FoundationNetworking
#endif

/// Engine for fetching and caching webpage content
actor WebPageEngine {
//	static let shared = WebPageCache()

	private let cacheDirectory: URL
	private let cacheDuration: TimeInterval = 3600 // 1 hour

	init() {
		// Get system cache directory
		let cacheDir = URL
			.cachesDirectory
			.appending(path: "com.webreader.mcp")

		self.cacheDirectory = cacheDir

		// Create cache directory if it doesn't exist
		try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
	}

	/// Fetch URL with caching support
	func fetch(
		url: URL,
		renderJS: Bool,
		ignoreCache: Bool,
		httpMethod: String = "GET",
		userAgent: String? = nil,
		customHeaders: [String: String] = [:]
	) async throws -> CacheResponse {
		let cacheURL = cacheFileURL(for: url, hasRenderedJS: renderJS)
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

		var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
		request.httpMethod = httpMethod

		// Set custom user agent if provided
		if let userAgent = userAgent {
			request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
		}

		// Add custom headers, filtering out potentially problematic ones
		let blockedHeaders = Set(["host", "content-length", "connection"])
		for (key, value) in customHeaders {
			let lowercaseKey = key.lowercased()
			guard !blockedHeaders.contains(lowercaseKey) else { continue }
			request.setValue(value, forHTTPHeaderField: key)
		}
		// Cache miss or stale - fetch fresh data
		let responseAndData: (Data, URLResponse)
		if renderJS {
			#if canImport(WebKit)
			responseAndData = try await loadJSRenderedPage(urlRequest: request)
			#else
			let renderer = LinuxJSRenderer()
			responseAndData = try await renderer.render(urlRequest: request, timeoutSeconds: 45)
			#endif
		} else {
			responseAndData = try await URLSession.shared.data(for: request)
		}
		let (data, response) = responseAndData

		// Cache the result if successful
		if let httpResponse = response as? HTTPURLResponse,
		   (200...299).contains(httpResponse.statusCode) {
			try saveToCache(data: data, url: url, hasRenderedJS: renderJS, contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"))
		}

		return CacheResponse(
			data: data,
			response: response,
			cacheHit: false,
			cacheAge: nil,
			cacheTTL: cacheDuration)
	}

	#if canImport(WebKit)
	@MainActor
	private func loadJSRenderedPage(urlRequest: URLRequest) async throws -> (Data, URLResponse) {
		let config = WKWebViewConfiguration()
		config.preferences.javaScriptCanOpenWindowsAutomatically = false
		config.suppressesIncrementalRendering = true
		config.mediaTypesRequiringUserActionForPlayback = .all

		let continuationProxy = ContinuationProxy<Void, Error>()

		let delegate = SimpleNavDelegate { _ /*webView*/, _ /*navigation*/, error in
			// navigation completed. start hashing content in short intervals to guess at rendering finish
			if let error {
				continuationProxy.resume(throwing: error)
			} else {
				continuationProxy.resume()
			}
		}

		let webView = WKWebView(frame: CGRect(origin: .zero, size: CGSize(width: 1920, height: 1080)), configuration: config)
		webView.navigationDelegate = delegate

		webView.load(urlRequest)

		try await withUnsafeThrowingContinuation { continuation in
			continuationProxy.setContinuation(continuation)
		}

		let htmlExtractJS = "document.documentElement.outerHTML"
		@MainActor
		@Sendable
		func extractHTML() async throws -> String {
			let html = try await webView.evaluateJavaScript(htmlExtractJS, contentWorld: .page) as? String

			return html ?? ""
		}

		@Sendable
		func hashDOM() async throws -> Insecure.MD5Digest {
			let html = try await extractHTML()
			return Insecure.MD5.hash(data: Data(html.utf8))
		}

		let waitForRenderSettle = TimeoutTask(timeout: .seconds(15), shouldUseStructuredTasks: true) { () async throws(BasicTimeoutError) in
			try await captureAnyError(isolation: self, errorType: BasicTimeoutError.self, {
				var hash = try await hashDOM()
				var successes = 0
				while Task.isCancelled == false, successes < 3 {
					try await Task.sleep(for: .milliseconds(500))
					let newHash = try await hashDOM()
					guard hash == newHash else {
						hash = newHash
						continue
					}

					successes += 1
				}
			})
		}
		try await withTaskCancellationHandler(
			operation: {
				try await waitForRenderSettle.value
			},
			onCancel: {
				waitForRenderSettle.cancel()
			})

		let data = try await Data(extractHTML().utf8)

		guard let response = delegate.capturedResponse else {
			throw SimpleError(message: "No response captured")
		}

		return (data, response)
	}
	#endif

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
	private func saveToCache(data: Data, url: URL, hasRenderedJS: Bool, contentType: String?) throws {
		let cacheURL = cacheFileURL(for: url, hasRenderedJS: hasRenderedJS)
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
	private func cacheFileURL(for url: URL, hasRenderedJS: Bool) -> URL {
		// Generate filename from URL hash
		let urlString = url.absoluteString
		let hash = Insecure.MD5.hash(data: Data("\(urlString)-hasRenderedJS-\(hasRenderedJS)".utf8))
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

	#if canImport(WebKit)
	private final class SimpleNavDelegate: NSObject, WKNavigationDelegate {
		let finishNavigation: @Sendable @MainActor (WKWebView, WKNavigation, Error?) -> Void

		var capturedResponse: URLResponse?

		init(finishNavigation: @Sendable @escaping (WKWebView, WKNavigation, Error?) -> Void) {
			self.finishNavigation = finishNavigation
		}

		func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
			finishNavigation(webView, navigation, nil)
		}

		func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
			finishNavigation(webView, navigation, error)
		}

		func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
			self.capturedResponse = navigationResponse.response
			return .allow
		}
	}
	#endif
}

enum BasicTimeoutError: TimedOutError, TypedWrappingError {
	typealias Context = Void


	case timedOut
	case cancelled
	case other(Error)

	static func wrap(_ anyError: any Error) -> BasicTimeoutError {
		.other(anyError)
	}
}
