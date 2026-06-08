import Foundation

/// Debug-only logging shim. Compiles to a no-op in Release builds, so
/// diagnostic chatter never ships to the App Store — keeping internal state
/// out of the device console and avoiding stray `print` in production.
///
/// Use in place of `print`. Same call shape (variadic, `separator`,
/// `terminator`), so it's a drop-in replacement.
@inline(__always)
func dlog(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    #if DEBUG
    print(items.map { "\($0)" }.joined(separator: separator), terminator: terminator)
    #endif
}
