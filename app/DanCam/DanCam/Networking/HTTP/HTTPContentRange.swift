import Foundation

/// Wrap a raw entity-tag (the list's `{seq}-{bytes}`) in literal double quotes so
/// it octet-matches the Pi's quoted `ETag` for a strong `If-Range` comparison.
/// Mirrors the Pi `clips.rs#http_etag`. Note `"\(rawETag)"` would *not* add the
/// quotes -- the escaped `"\"\(rawETag)\""` is what embeds them.
nonisolated func httpEntityTag(_ rawETag: String) -> String {
    "\"\(rawETag)\""
}

/// Response-side parser for the `Content-Range` header a `206` carries
/// (`bytes <start>-<end>/<total>`). The pull loop uses this to validate a
/// resumed partial before appending it.
nonisolated enum HTTPContentRange {
    /// Returns `nil` for an unknown total (`bytes */<n>`) or any malformed value.
    static func parse(_ value: String) -> (start: UInt64, end: UInt64, total: UInt64)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("bytes ") else {
            return nil
        }

        let spec = trimmed.dropFirst("bytes ".count)
        let slashParts = spec.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard slashParts.count == 2, let total = UInt64(slashParts[1]) else {
            return nil
        }

        let rangeParts = slashParts[0]
            .split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard
            rangeParts.count == 2,
            let start = UInt64(rangeParts[0]),
            let end = UInt64(rangeParts[1]),
            start <= end
        else {
            return nil
        }

        return (start: start, end: end, total: total)
    }
}
