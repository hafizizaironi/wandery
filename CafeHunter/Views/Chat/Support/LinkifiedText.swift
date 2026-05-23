import Foundation
import SwiftUI

/// Detect URLs in chat text and return an `AttributedString` with them
/// styled as terracotta-tinted underlined links. Shared by
/// `MessageBubbleView` (text bubbles) and `PostReferenceBubbleView`
/// (reply-text bubbles).
///
/// Uses `NSDataDetector` for autodetection — same engine UIKit's
/// `UITextView.dataDetectorTypes` uses, so detected URLs agree with
/// what users see in other system-rendered text. We advance the search
/// anchor in the AttributedString after each hit so repeated URLs in
/// the same message resolve to the right occurrence.
enum LinkifiedText {
    static func attributed(_ text: String) -> AttributedString {
        var attr = AttributedString(text)
        guard !text.isEmpty,
              let detector = try? NSDataDetector(
                  types: NSTextCheckingResult.CheckingType.link.rawValue
              )
        else { return attr }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: nsRange)
        var searchStart = attr.startIndex
        for match in matches {
            guard let url = match.url,
                  let swiftRange = Range(match.range, in: text)
            else { continue }
            let matched = String(text[swiftRange])
            // Slice the AttributedString at `searchStart` — slice indices
            // are the same indices as the parent, so a range found in
            // the slice is directly usable on `attr`.
            let slice = attr[searchStart..<attr.endIndex]
            if let subRange = slice.range(of: matched) {
                attr[subRange].link = url
                attr[subRange].foregroundColor = AppTheme.accentAction
                attr[subRange].underlineStyle = .single
                searchStart = subRange.upperBound
            }
        }
        return attr
    }
}
