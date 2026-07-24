import Foundation

public enum PartialWordCompletion {
    public static func fragment(in prefix: String) -> String? {
        guard let last = prefix.last, last.isLetter else { return nil }

        let reversed = prefix.reversed()
        let letters = reversed.prefix { $0.isLetter }
        let fragment = String(letters.reversed())
        guard fragment.count >= 2 else { return nil }

        let start = prefix.index(prefix.endIndex, offsetBy: -fragment.count)
        if start > prefix.startIndex {
            let previous = prefix[prefix.index(before: start)]
            guard previous != "@", previous != "#", previous != "_" else {
                return nil
            }
        }
        return fragment
    }

    public static func sanitize(
        _ rawCompletion: String,
        after fragment: String,
        candidates: [String]
    ) -> String? {
        var candidate = rawCompletion
        while candidate.first == "\n" || candidate.first == "\r" {
            candidate.removeFirst()
        }
        while candidate.first == " " || candidate.first == "\t" {
            candidate.removeFirst()
        }
        if let newline = candidate.firstIndex(where: {
            $0 == "\n" || $0 == "\r"
        }) {
            candidate = String(candidate[..<newline])
        }
        guard
            !candidate.isEmpty,
            !candidate.hasPrefix("Continuation:"),
            !candidate.hasPrefix("Text:")
        else {
            return nil
        }

        let rawSuffix = String(candidate.prefix { $0.isLetter })
        guard
            !rawSuffix.isEmpty,
            rawSuffix.caseInsensitiveCompare(fragment) != .orderedSame
        else {
            return nil
        }

        let options = candidates.compactMap { word -> String? in
            guard
                word.count > fragment.count,
                word.lowercased().hasPrefix(fragment.lowercased())
            else {
                return nil
            }
            return String(word.dropFirst(fragment.count))
        }
        guard !options.isEmpty else { return nil }

        let normalizedRaw = rawSuffix.lowercased()
        if let exact = options.first(where: {
            $0.lowercased() == normalizedRaw
        }) {
            return exact + candidate.dropFirst(rawSuffix.count)
        }
        if let contained = options.first(where: {
            normalizedRaw.hasPrefix($0.lowercased())
        }) {
            return contained + candidate.dropFirst(rawSuffix.count)
        }
        if let completion = options.first(where: {
            $0.lowercased().hasPrefix(normalizedRaw)
        }) {
            return completion + candidate.dropFirst(rawSuffix.count)
        }

        return nil
    }
}
