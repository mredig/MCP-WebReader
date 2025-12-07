import Foundation

extension URL {
	public static var cachesDirectory: URL {
		URL.homeDirectory.appending(path: ".caches")
	}
}
