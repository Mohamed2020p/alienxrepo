import SwiftUI
import UIKit

// MARK: - Colours

extension Color {
    /// `Color(hex: 0xD9A93A)`, sRGB.
    init(hex: UInt32, opacity: Double = 1.0) {
        let r: Double = Double((hex >> 16) & 0xFF) / 255.0
        let g: Double = Double((hex >> 8) & 0xFF) / 255.0
        let b: Double = Double(hex & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

/// The look of the lounge: gold, emerald cloth, midnight, cream, Dutch orange, delft blue. No neon, no glow.
enum Theme {
    static let gold: Color = Color(hex: 0xD9A93A)
    static let goldDark: Color = Color(hex: 0x8F6D1C)
    static let emerald: Color = Color(hex: 0x0B4B2A)
    static let midnight: Color = Color(hex: 0x0A1622)
    static let cream: Color = Color(hex: 0xF3EBD8)
    static let orange: Color = Color(hex: 0xF26B1D)
    static let delft: Color = Color(hex: 0x2E5FA8)

    /// A layout scale for the screen: 1.0 on an iPhone SE / iPhone landscape, up to 1.6 on an iPad Pro.
    static func scale(for size: CGSize) -> CGFloat {
        let s: CGFloat = size.height / 390.0
        return min(max(s, 0.85), 1.6)
    }

    static func font(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        return Font.system(size: size, weight: weight, design: .serif)
    }

    /// Power bar colour: green -> orange -> red.
    static func powerColor(_ v: Double) -> Color {
        let t: Double = min(max(v, 0.0), 1.0)
        let green: (Double, Double, Double) = (0.24, 0.64, 0.36)
        let amber: (Double, Double, Double) = (0.95, 0.42, 0.11)
        let red: (Double, Double, Double) = (0.78, 0.21, 0.17)
        if t < 0.5 {
            return mix(green, amber, t / 0.5)
        }
        return mix(amber, red, (t - 0.5) / 0.5)
    }

    private static func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> Color {
        let r: Double = a.0 + (b.0 - a.0) * t
        let g: Double = a.1 + (b.1 - a.1) * t
        let bl: Double = a.2 + (b.2 - a.2) * t
        return Color(.sRGB, red: r, green: g, blue: bl, opacity: 1.0)
    }
}

// MARK: - Panel

/// Semi-transparent midnight panel with a gold border.
struct GoldPanel: ViewModifier {
    var cornerRadius: CGFloat = 18
    var fillOpacity: Double = 0.84
    var borderWidth: CGFloat = 2

    func body(content: Content) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(Theme.midnight.opacity(fillOpacity)))
            .overlay(shape.strokeBorder(Theme.gold, lineWidth: borderWidth))
    }
}

extension View {
    func goldPanel(cornerRadius: CGFloat = 18, fillOpacity: Double = 0.84, borderWidth: CGFloat = 2) -> some View {
        return self.modifier(GoldPanel(cornerRadius: cornerRadius, fillOpacity: fillOpacity, borderWidth: borderWidth))
    }
}

// MARK: - Buttons

/// Full-width gold button (`prominent`) or a midnight button with a gold outline.
struct GoldButtonStyle: ButtonStyle {
    var prominent: Bool = true
    var height: CGFloat = 46
    var fontSize: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
        let fill: Color = prominent ? Theme.gold : Theme.midnight.opacity(0.7)
        let textColor: Color = prominent ? Theme.midnight : Theme.cream
        let border: Color = prominent ? Theme.goldDark : Theme.gold
        let pressed: Bool = configuration.isPressed
        return configuration.label
            .font(Theme.font(fontSize))
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(border, lineWidth: 1.5))
            .opacity(pressed ? 0.75 : 1.0)
            .scaleEffect(pressed ? 0.97 : 1.0)
    }
}

/// A pill-shaped choice (difficulty picker).
struct PillChoice: View {
    let title: String
    let selected: Bool
    let height: CGFloat
    let fontSize: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font(fontSize))
                .foregroundColor(selected ? Theme.midnight : Theme.cream)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(Capsule().fill(selected ? Theme.gold : Theme.midnight.opacity(0.55)))
                .overlay(Capsule().strokeBorder(Theme.gold, lineWidth: selected ? 0 : 1.5))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// A round icon button (pause, close ...).
struct CircleIconButton: View {
    let systemName: String
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundColor(Theme.cream)
                .frame(width: size, height: size)
                .background(Circle().fill(Theme.midnight.opacity(0.75)))
                .overlay(Circle().strokeBorder(Theme.gold, lineWidth: 1.5))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Images from the Data folder

/// An image from `Data/` (via `DataStore.image`); a plain colour when the file is missing.
struct DataImage: View {
    let path: String
    let fit: Bool
    let fallback: Color

    init(_ path: String, fit: Bool = true, fallback: Color = Color(hex: 0x2E5FA8, opacity: 0.5)) {
        self.path = path
        self.fit = fit
        self.fallback = fallback
    }

    var body: some View {
        if let ui: UIImage = DataStore.image(path) {
            if fit {
                Image(uiImage: ui).resizable().scaledToFit()
            } else {
                Image(uiImage: ui).resizable().scaledToFill()
            }
        } else {
            Rectangle().fill(fallback)
        }
    }
}

/// A dimmed full-screen backdrop that swallows touches (used behind the pause menu, settings ...).
struct DimBackdrop: View {
    var opacity: Double = 0.55

    var body: some View {
        Color.black
            .opacity(opacity)
            .contentShape(Rectangle())
            .ignoresSafeArea()
    }
}
