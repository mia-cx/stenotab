public enum PromptContextRetentionMigration {
    public static let currentDisclosureVersion = 1

    public static func migrate(
        _ configuration: PromptConfiguration,
        fromDisclosureVersion version: Int
    ) -> PromptConfiguration {
        guard version < currentDisclosureVersion else {
            return configuration
        }
        var migrated = configuration
        migrated.context.includeClipboard = false
        migrated.context.includeOCR = false
        return migrated
    }
}
