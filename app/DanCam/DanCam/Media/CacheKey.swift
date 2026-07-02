import Foundation

/// Canonicalize an HTTP entity-tag into a stable filesystem token so the quoted
/// (`"7-10"`), unquoted (`7-10`), and weak (`W/"7-10"`) spellings of one validator
/// all resolve to the same cache filename. Shared by every on-disk media cache
/// keyed by `(id, etag)` (`ClipCache`, `ThumbnailCache`) so they agree byte-for-byte
/// on what a representation is.
nonisolated enum CacheKey {
    static func etagToken(_ etag: String) -> String {
        var value = etag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("W/") {
            value.removeFirst(2)
        }
        if value.count >= 2, value.first == "\"", value.last == "\"" {
            value.removeFirst()
            value.removeLast()
        }

        let bytes = Array(value.utf8)
        guard bytes.isEmpty == false else { return "empty" }

        return bytes.map { byte in
            String(format: "%02x", byte)
        }.joined()
    }
}
