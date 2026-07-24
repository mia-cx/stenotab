import Foundation

public enum LocalServerCompatibility {
    public static func matchingModelID(
        for profile: LocalModelProfile,
        advertisedModelIDs: [String]
    ) -> String? {
        let compatibleIDs = profile.compatibleServerModelIDs
        return advertisedModelIDs.first { identifier in
            compatibleIDs.contains(identifier) ||
                compatibleIDs.contains(URL(filePath: identifier).lastPathComponent)
        }
    }

    public static func canServe(
        _ profile: LocalModelProfile,
        advertisedModelIDs: [String]
    ) -> Bool {
        matchingModelID(
            for: profile,
            advertisedModelIDs: advertisedModelIDs
        ) != nil
    }
}
