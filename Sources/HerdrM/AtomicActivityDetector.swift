import Foundation

/// Detects Atomic's separately styled loader glyph on a status line or editor border.
enum AtomicActivityDetector {
    private static let styledGlyph = #"^(?:(?:\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\))|[\s─])*∀(?:(?:\x1B\[[0-?]*[ -/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\))+(?:\s|$)|\s*$)"#

    static func isWorking(in text: String) -> Bool {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .contains { String($0).range(of: styledGlyph, options: .regularExpression) != nil }
    }
}
