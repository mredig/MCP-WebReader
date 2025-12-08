import Foundation

public final class AnySendable<Wrapped: Sendable>: @unchecked Sendable {
	public private(set) var wrapped: Wrapped

	let lock = NSLock()

	public init(_ wrappedValue: Wrapped) {
		self.wrapped = wrappedValue
	}

	public func updateValue(_ newValue: Wrapped) {
		lock.withLock({ wrapped = newValue })
	}
}
