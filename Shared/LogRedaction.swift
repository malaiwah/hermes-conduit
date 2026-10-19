import Foundation

/// Error text that is safe to log with `privacy: .public`: every URL in it
/// becomes `<url>`. A URLError's description carries the failing request's
/// address (a dashboard, relay or speech server, with its path and query),
/// and a public log line is readable by anyone handed a sysdiagnose.
enum LogRedaction {
    /// `String(describing:)` of the error, URLs replaced.
    static func describing(_ error: Error) -> String {
        redactingURLs(String(describing: error))
    }

    /// The same for an error that may be absent ("nil").
    static func describing(_ error: Error?) -> String {
        error.map { describing($0) } ?? "nil"
    }

    /// The error's localized description, URLs replaced.
    static func message(_ error: Error) -> String {
        redactingURLs(error.localizedDescription)
    }

    static func redactingURLs(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return urlPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "<url>")
    }

    /// A scheme, "://" and everything up to whitespace, a quote, an angle
    /// or curly bracket. It never ends on the punctuation that follows a URL
    /// in prose or in NSError's userInfo list (", ", ".", ";", ")", "]"),
    /// but keeps it inside one, and covers IPv6 literal hosts.
    ///
    /// Only URLs: a host named without a scheme (a TLS error's "pretending
    /// to be “host”", a bare host:port) still reads as written.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^\s"'<>{}]*[^\s"'<>{},;.)\]]"#
    )
}
