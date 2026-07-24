import Foundation

public enum HuggingFaceRepositorySelection {
    public static func normalizedRepositoryID(
        from input: String
    ) -> String? {
        let trimmed = input.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let url = URL(string: trimmed),
           url.scheme?.lowercased() == "https",
           url.host?.lowercased() == "huggingface.co" {
            candidate = url.path.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        } else {
            candidate = trimmed.trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }

        let components = candidate.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard
            components.count == 2,
            components.allSatisfy({ isSafeRepositoryComponent(String($0)) })
        else {
            return nil
        }
        return components.joined(separator: "/")
    }

    public static func preferredGGUFFile(
        from filenames: [String]
    ) -> String? {
        let candidates = filenames.filter {
            $0.lowercased().hasSuffix(".gguf")
                && !isSplitGGUF($0)
        }
        let priorities = [
            "q4_k_m.gguf",
            "q4_k_s.gguf",
            "q5_k_m.gguf",
            "q5_k_s.gguf",
            "q8_0.gguf",
        ]
        for suffix in priorities {
            if let match = candidates.first(where: {
                $0.lowercased().hasSuffix(suffix)
            }) {
                return match
            }
        }
        return candidates.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }.first
    }

    private static func isSafeRepositoryComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || $0 == "-"
                    || $0 == "_"
                    || $0 == "."
            }
    }

    private static func isSplitGGUF(_ filename: String) -> Bool {
        filename.range(
            of: #"-\d{5}-of-\d{5}\.gguf$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
