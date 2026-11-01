import Foundation

extension Date {
    /// Vault files store dates as integer milliseconds; models round at creation so
    /// an in-memory value and its decoded copy compare equal.
    public var millisecondPrecision: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
