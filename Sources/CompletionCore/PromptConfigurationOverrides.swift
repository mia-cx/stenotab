import Foundation

extension PromptConfiguration {
    /// Stores only values that differ from a known set of defaults. Applying
    /// these overrides to newer bundled defaults preserves deliberate edits
    /// without freezing untouched prompt components at an older version.
    public struct Overrides: Codable, Sendable, Equatable {
        public struct FramingOverrides: Codable, Sendable, Equatable {
            public var contextHeading: String?
            public var applicationPrefix: String?
            public var websitePrefix: String?
            public var inputKindPrefix: String?
            public var ocrHeading: String?
            public var clipboardHeading: String?
            public var inputHistoryHeading: String?
            public var assessmentHeading: String?
            public var customVoiceHeading: String?
            public var suffixHeading: String?
            public var textHeading: String?

            init(
                configuration: Framing,
                relativeTo defaults: Framing
            ) {
                contextHeading = Self.difference(
                    configuration.contextHeading,
                    defaults.contextHeading
                )
                applicationPrefix = Self.difference(
                    configuration.applicationPrefix,
                    defaults.applicationPrefix
                )
                websitePrefix = Self.difference(
                    configuration.websitePrefix,
                    defaults.websitePrefix
                )
                inputKindPrefix = Self.difference(
                    configuration.inputKindPrefix,
                    defaults.inputKindPrefix
                )
                ocrHeading = Self.difference(
                    configuration.ocrHeading,
                    defaults.ocrHeading
                )
                clipboardHeading = Self.difference(
                    configuration.clipboardHeading,
                    defaults.clipboardHeading
                )
                inputHistoryHeading = Self.difference(
                    configuration.inputHistoryHeading,
                    defaults.inputHistoryHeading
                )
                assessmentHeading = Self.difference(
                    configuration.assessmentHeading,
                    defaults.assessmentHeading
                )
                customVoiceHeading = Self.difference(
                    configuration.customVoiceHeading,
                    defaults.customVoiceHeading
                )
                suffixHeading = Self.difference(
                    configuration.suffixHeading,
                    defaults.suffixHeading
                )
                textHeading = Self.difference(
                    configuration.textHeading,
                    defaults.textHeading
                )
            }

            public var isEmpty: Bool {
                contextHeading == nil
                    && applicationPrefix == nil
                    && websitePrefix == nil
                    && inputKindPrefix == nil
                    && ocrHeading == nil
                    && clipboardHeading == nil
                    && inputHistoryHeading == nil
                    && assessmentHeading == nil
                    && customVoiceHeading == nil
                    && suffixHeading == nil
                    && textHeading == nil
            }

            func apply(to framing: inout Framing) {
                if let contextHeading {
                    framing.contextHeading = contextHeading
                }
                if let applicationPrefix {
                    framing.applicationPrefix = applicationPrefix
                }
                if let websitePrefix {
                    framing.websitePrefix = websitePrefix
                }
                if let inputKindPrefix {
                    framing.inputKindPrefix = inputKindPrefix
                }
                if let ocrHeading {
                    framing.ocrHeading = ocrHeading
                }
                if let clipboardHeading {
                    framing.clipboardHeading = clipboardHeading
                }
                if let inputHistoryHeading {
                    framing.inputHistoryHeading = inputHistoryHeading
                }
                if let assessmentHeading {
                    framing.assessmentHeading = assessmentHeading
                }
                if let customVoiceHeading {
                    framing.customVoiceHeading = customVoiceHeading
                }
                if let suffixHeading {
                    framing.suffixHeading = suffixHeading
                }
                if let textHeading {
                    framing.textHeading = textHeading
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
        public var systemInstruction: String?
        public var completionInstruction: String?
        public var framing: FramingOverrides?
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
            systemInstruction = configuration.systemInstruction
                == defaults.systemInstruction
                ? nil
                : configuration.systemInstruction
            completionInstruction = configuration.completionInstruction
                == defaults.completionInstruction
                ? nil
                : configuration.completionInstruction
            let framingOverrides = FramingOverrides(
                configuration: configuration.framing,
                relativeTo: defaults.framing
            )
            framing = framingOverrides.isEmpty ? nil : framingOverrides
            debugMode = configuration.debugMode == defaults.debugMode
                ? nil
                : configuration.debugMode
        }

        public var isEmpty: Bool {
            context == nil
                && voice == nil
                && systemInstruction == nil
                && completionInstruction == nil
                && framing == nil
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
            if let systemInstruction {
                result.systemInstruction = systemInstruction
            }
            if let completionInstruction {
                result.completionInstruction = completionInstruction
            }
            framing?.apply(to: &result.framing)
            if let debugMode {
                result.debugMode = debugMode
            }
            return result
        }
    }
}
