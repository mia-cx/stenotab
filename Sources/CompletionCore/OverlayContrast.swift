import Foundation

public struct OverlayRGBColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(
        red: Double,
        green: Double,
        blue: Double,
        alpha: Double = 1
    ) {
        self.red = Self.clamp(red)
        self.green = Self.clamp(green)
        self.blue = Self.clamp(blue)
        self.alpha = Self.clamp(alpha)
    }

    private static func clamp(_ component: Double) -> Double {
        min(max(component, 0), 1)
    }
}

public enum OverlayContrast {
    public static func foreground(
        explicitForeground: OverlayRGBColor?,
        background: OverlayRGBColor?,
        fallback: OverlayRGBColor
    ) -> OverlayRGBColor {
        if let explicitForeground {
            return explicitForeground
        }
        guard let background else {
            return fallback
        }
        let luminance = relativeLuminance(background)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast
            ? OverlayRGBColor(red: 0, green: 0, blue: 0)
            : OverlayRGBColor(red: 1, green: 1, blue: 1)
    }

    private static func relativeLuminance(
        _ color: OverlayRGBColor
    ) -> Double {
        0.2126 * linear(color.red)
            + 0.7152 * linear(color.green)
            + 0.0722 * linear(color.blue)
    }

    private static func linear(_ component: Double) -> Double {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}
