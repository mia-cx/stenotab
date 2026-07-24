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
        let candidate = rawCompletion.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
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
            return exact
        }
        if let contained = options.first(where: {
            normalizedRaw.hasPrefix($0.lowercased())
        }) {
            return contained
        }
        if let completion = options.first(where: {
            $0.lowercased().hasPrefix(normalizedRaw)
        }) {
            return completion
        }

        return options.enumerated().min { left, right in
            let leftDistance = editDistance(
                normalizedRaw,
                left.element.lowercased()
            )
            let rightDistance = editDistance(
                normalizedRaw,
                right.element.lowercased()
            )
            if leftDistance == rightDistance {
                return left.offset < right.offset
            }
            return leftDistance < rightDistance
        }?.element
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let left = Array(lhs)
        let right = Array(rhs)
        var previous = Array(0...right.count)

        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = [leftIndex + 1]
            for (rightIndex, rightCharacter) in right.enumerated() {
                current.append(
                    min(
                        current[rightIndex] + 1,
                        previous[rightIndex + 1] + 1,
                        previous[rightIndex]
                            + (leftCharacter == rightCharacter ? 0 : 1)
                    )
                )
            }
            previous = current
        }
        return previous[right.count]
    }
}
