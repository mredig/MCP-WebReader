#if os(Linux)
import Foundation
import FoundationNetworking
import SwiftPizzaSnips

public enum LinuxJSRendererError: Error, LocalizedError {
	case chromiumNotFound
	case nonZeroExit(code: Int32, stderr: String)
	case invalidURL
	case timeout

	public var errorDescription: String? {
		switch self {
		case .chromiumNotFound:
			return "No Chromium/Chrome binary found. Set WEBREADER_CHROME_PATH or install chromium/google-chrome."
		case .nonZeroExit(let code, let stderr):
			return "Headless browser exited with code \(code). Stderr: \(stderr)"
		case .invalidURL:
			return "Invalid URL for headless renderer."
		case .timeout:
			return "Headless render timed out."
		}
	}
}

public struct LinuxJSRenderer {
	public init() {}

	// You can override the browser path by setting WEBREADER_CHROME_PATH
	private static let candidateBinaries = [
		"chromium",
		"chromium-browser",
		"google-chrome",
		"google-chrome-stable",
		"chrome"
	]

	private static func which(_ name: String) -> String? {
		let env = ProcessInfo.processInfo.environment
		let paths = (env["PATH"] ?? "/usr/bin:/bin:/usr/local/bin").split(separator: ":").map(String.init)
		for dir in paths {
			let candidate = URL(filePath: dir).appendingPathComponent(name)
			if FileManager.default.isExecutableFile(atPath: candidate.path) {
				return candidate.path
			}
		}
		return nil
	}

	private static func findBrowserBinary(env: [String: String]) -> String? {
		if let override = env["WEBREADER_CHROME_PATH"], FileManager.default.isExecutableFile(atPath: override) {
			return override
		}
		for name in candidateBinaries {
			if let path = which(name) {
				return path
			}
		}
		return nil
	}

	/// Render the given request using headless Chromium and return (Data, URLResponse).
	/// - Note: Only GET is supported; user-agent is honored; custom headers are not supported in this simple mode.
	public func render(urlRequest: URLRequest, timeoutSeconds: TimeInterval = 15) async throws -> (Data, URLResponse) {
		guard let url = urlRequest.url else { throw LinuxJSRendererError.invalidURL }

		let env = ProcessInfo.processInfo.environment
		guard let browser = Self.findBrowserBinary(env: env) else {
			throw LinuxJSRendererError.chromiumNotFound
		}

		// Honor GET only; ignore custom headers (Chromium CLI does not easily support them without CDP).
		var args: [String] = [
			"--headless=new",
			"--disable-gpu",
			"--no-sandbox",
			"--disable-dev-shm-usage",
			"--hide-scrollbars",
			"--virtual-time-budget=\(Int(timeoutSeconds * 1000))",
			"--dump-dom"
		]

		// User-Agent if present
		if let ua = urlRequest.value(forHTTPHeaderField: "User-Agent"), ua.isEmpty == false {
			args.append("--user-agent=\(ua)")
		}

		args.append(url.absoluteString)

		let proc = Process()
		proc.executableURL = URL(fileURLWithPath: browser)
		proc.arguments = args

		let outPipe = Pipe()
		let errPipe = Pipe()
		proc.standardOutput = outPipe
		proc.standardError = errPipe

		// let didTerminate = ManagedAtomic<Bool>(false)
		let didTerminate = AnySendable(false)

		// Use a simple timeout: if overflows, kill process
		let timeoutTask = Task {
			try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
			guard didTerminate.wrapped == false else { return }
			proc.terminate()
		}

		do {
			try proc.run()
		} catch {
			timeoutTask.cancel()
			throw error
		}

		await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
			proc.terminationHandler = { _ in c.resume() }
		}
		// didTerminate.store(true, ordering: .relaxed)
		didTerminate.updateValue(true)
		timeoutTask.cancel()

		let stdoutData = outPipe.fileHandleForReading.readDataToEndOfFile()
		let stderrData = errPipe.fileHandleForReading.readDataToEndOfFile()

		if proc.terminationStatus != 0 {
			let err = String(decoding: stderrData, as: UTF8.self)
			throw LinuxJSRendererError.nonZeroExit(code: proc.terminationStatus, stderr: err)
		}

		// Synthesize a 200 HTML response (consistent with your cache path)
		let response = HTTPURLResponse(
			url: url,
			statusCode: 200,
			httpVersion: "HTTP/1.1",
			headerFields: ["Content-Type": "text/html; charset=UTF-8"]
		)!

		return (stdoutData, response)
	}
}
#endif
