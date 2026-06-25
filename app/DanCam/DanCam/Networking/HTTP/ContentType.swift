import Foundation

nonisolated enum ContentType {
    static func mediaType(from headerValue: String) -> String? {
        headerValue
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func boundary(from headerValue: String) -> String? {
        let parameters = headerValue
            .split(separator: ";", omittingEmptySubsequences: false)
            .dropFirst()

        for parameter in parameters {
            let parts = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }

            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "boundary" else { continue }

            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }

            return value.isEmpty ? nil : value
        }

        return nil
    }
}
