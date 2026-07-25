import Foundation

extension PromptConfiguration {
    /// Stores only values that differ from a known set of defaults. Applying
    /// these overrides to newer bundled defaults preserves deliberate edits
    /// without freezing untouched prompt components at an older version.
    public struct Overrides: Codable, Sendable, Equatable {
        public struct BaseFramingOverrides: Codable, Sendable, Equatable {
            public var openingInstruction: String?
            public var focusedContextHeading: String?
            public var focusedActivityPrefix: String?
            public var focusedWebsiteConnector: String?
            public var focusedApplicationConnector: String?
            public var inputHistoryHeading: String?
            public var seedExamplesHeading: String?
            public var relevantInputHistoryHeading: String?
            public var assessmentHeading: String?
            public var customVoiceHeading: String?
            public var perspectiveFix: String?
            public var ocrHeading: String?
            public var clipboardHeading: String?
            public var finalBoundary: String?
            public var writingHeading: String?
            public var examplePrefix: String?

            init(
                configuration: BaseFraming,
                relativeTo defaults: BaseFraming
            ) {
                openingInstruction = Self.difference(
                    configuration.openingInstruction,
                    defaults.openingInstruction
                )
                focusedContextHeading = Self.difference(
                    configuration.focusedContextHeading,
                    defaults.focusedContextHeading
                )
                focusedActivityPrefix = Self.difference(
                    configuration.focusedActivityPrefix,
                    defaults.focusedActivityPrefix
                )
                focusedWebsiteConnector = Self.difference(
                    configuration.focusedWebsiteConnector,
                    defaults.focusedWebsiteConnector
                )
                focusedApplicationConnector = Self.difference(
                    configuration.focusedApplicationConnector,
                    defaults.focusedApplicationConnector
                )
                inputHistoryHeading = Self.difference(
                    configuration.inputHistoryHeading,
                    defaults.inputHistoryHeading
                )
                seedExamplesHeading = Self.difference(
                    configuration.seedExamplesHeading,
                    defaults.seedExamplesHeading
                )
                relevantInputHistoryHeading = Self.difference(
                    configuration.relevantInputHistoryHeading,
                    defaults.relevantInputHistoryHeading
                )
                assessmentHeading = Self.difference(
                    configuration.assessmentHeading,
                    defaults.assessmentHeading
                )
                customVoiceHeading = Self.difference(
                    configuration.customVoiceHeading,
                    defaults.customVoiceHeading
                )
                perspectiveFix = Self.difference(
                    configuration.perspectiveFix,
                    defaults.perspectiveFix
                )
                ocrHeading = Self.difference(
                    configuration.ocrHeading,
                    defaults.ocrHeading
                )
                clipboardHeading = Self.difference(
                    configuration.clipboardHeading,
                    defaults.clipboardHeading
                )
                finalBoundary = Self.difference(
                    configuration.finalBoundary,
                    defaults.finalBoundary
                )
                writingHeading = Self.difference(
                    configuration.writingHeading,
                    defaults.writingHeading
                )
                examplePrefix = Self.difference(
                    configuration.examplePrefix,
                    defaults.examplePrefix
                )
            }

            public var isEmpty: Bool {
                openingInstruction == nil
                    && focusedContextHeading == nil
                    && focusedActivityPrefix == nil
                    && focusedWebsiteConnector == nil
                    && focusedApplicationConnector == nil
                    && inputHistoryHeading == nil
                    && seedExamplesHeading == nil
                    && relevantInputHistoryHeading == nil
                    && assessmentHeading == nil
                    && customVoiceHeading == nil
                    && perspectiveFix == nil
                    && ocrHeading == nil
                    && clipboardHeading == nil
                    && finalBoundary == nil
                    && writingHeading == nil
                    && examplePrefix == nil
            }

            func apply(to framing: inout BaseFraming) {
                if let openingInstruction {
                    framing.openingInstruction = openingInstruction
                }
                if let focusedContextHeading {
                    framing.focusedContextHeading = focusedContextHeading
                }
                if let focusedActivityPrefix {
                    framing.focusedActivityPrefix = focusedActivityPrefix
                }
                if let focusedWebsiteConnector {
                    framing.focusedWebsiteConnector =
                        focusedWebsiteConnector
                }
                if let focusedApplicationConnector {
                    framing.focusedApplicationConnector =
                        focusedApplicationConnector
                }
                if let inputHistoryHeading {
                    framing.inputHistoryHeading = inputHistoryHeading
                }
                if let seedExamplesHeading {
                    framing.seedExamplesHeading = seedExamplesHeading
                }
                if let relevantInputHistoryHeading {
                    framing.relevantInputHistoryHeading =
                        relevantInputHistoryHeading
                }
                if let assessmentHeading {
                    framing.assessmentHeading = assessmentHeading
                }
                if let customVoiceHeading {
                    framing.customVoiceHeading = customVoiceHeading
                }
                if let perspectiveFix {
                    framing.perspectiveFix = perspectiveFix
                }
                if let ocrHeading {
                    framing.ocrHeading = ocrHeading
                }
                if let clipboardHeading {
                    framing.clipboardHeading = clipboardHeading
                }
                if let finalBoundary {
                    framing.finalBoundary = finalBoundary
                }
                if let writingHeading {
                    framing.writingHeading = writingHeading
                }
                if let examplePrefix {
                    framing.examplePrefix = examplePrefix
                }
            }

            private static func difference(
                _ value: String,
                _ defaultValue: String
            ) -> String? {
                value == defaultValue ? nil : value
            }
        }

        public var context: ContextOptions?
        public var voice: VoiceOptions?
        public var base: BaseOptions?
        public var baseFraming: BaseFramingOverrides?
        public var systemInstruction: String?
        public var debugMode: Bool?

        public init(
            configuration: PromptConfiguration,
            relativeTo defaults: PromptConfiguration
        ) {
            context = configuration.context == defaults.context
                ? nil
                : configuration.context
            voice = configuration.voice == defaults.voice
                ? nil
                : configuration.voice
            base = configuration.base == defaults.base
                ? nil
                : configuration.base
            let baseFramingOverrides = BaseFramingOverrides(
                configuration: configuration.baseFraming,
                relativeTo: defaults.baseFraming
            )
            baseFraming = baseFramingOverrides.isEmpty
                ? nil
                : baseFramingOverrides
            systemInstruction = configuration.systemInstruction
                == defaults.systemInstruction
                ? nil
                : configuration.systemInstruction
            debugMode = configuration.debugMode == defaults.debugMode
                ? nil
                : configuration.debugMode
        }

        public var isEmpty: Bool {
            context == nil
                && voice == nil
                && base == nil
                && baseFraming == nil
                && systemInstruction == nil
                && debugMode == nil
        }

        public func applying(
            to defaults: PromptConfiguration
        ) -> PromptConfiguration {
            var result = defaults
            if let context {
                result.context = context
            }
            if let voice {
                result.voice = voice
            }
            if let base {
                result.base = base
            }
            baseFraming?.apply(to: &result.baseFraming)
            if let systemInstruction {
                result.systemInstruction = systemInstruction
            }
            if let debugMode {
                result.debugMode = debugMode
            }
            return result
        }
    }
}
