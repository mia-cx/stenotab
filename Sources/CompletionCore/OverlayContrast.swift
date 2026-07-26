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
    public static func presentationForeground(
        explicitForeground: OverlayRGBColor?,
        background: OverlayRGBColor?,
        fallback: OverlayRGBColor,
        preferredAlpha: Double = 0.34,
        minimumContrast: Double = 3
    ) -> OverlayRGBColor {
        if let explicitForeground {
            return OverlayRGBColor(
                red: explicitForeground.red,
                green: explicitForeground.green,
                blue: explicitForeground.blue,
                alpha: preferredAlpha
            )
        }
        guard let background else {
            return OverlayRGBColor(
                red: fallback.red,
                green: fallback.green,
                blue: fallback.blue,
                alpha: preferredAlpha
            )
        }

        let opaque = foreground(
            explicitForeground: nil,
            background: background,
            fallback: fallback
        )
        var lower = preferredAlpha
        var upper = 1.0
        if contrastAfterCompositing(
            foreground: opaque,
            background: background,
            alpha: lower
        ) >= minimumContrast {
            upper = lower
        } else {
            for _ in 0..<12 {
                let candidate = (lower + upper) / 2
                if contrastAfterCompositing(
                    foreground: opaque,
                    background: background,
                    alpha: candidate
                ) >= minimumContrast {
                    upper = candidate
                } else {
                    lower = candidate
                }
            }
        }
        return OverlayRGBColor(
            red: opaque.red,
            green: opaque.green,
            blue: opaque.blue,
            alpha: upper
        )
    }

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

    private static func contrastAfterCompositing(
        foreground: OverlayRGBColor,
        background: OverlayRGBColor,
        alpha: Double
    ) -> Double {
        let composite = OverlayRGBColor(
            red: foreground.red * alpha
                + background.red * (1 - alpha),
            green: foreground.green * alpha
                + background.green * (1 - alpha),
            blue: foreground.blue * alpha
                + background.blue * (1 - alpha)
        )
        let foregroundLuminance = relativeLuminance(composite)
        let backgroundLuminance = relativeLuminance(background)
        return (max(foregroundLuminance, backgroundLuminance) + 0.05)
            / (min(foregroundLuminance, backgroundLuminance) + 0.05)
    }
}
