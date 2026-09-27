import SwiftUI

/// Credits overlay, reachable from the main menu.
@MainActor
struct CreditsView: View {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    private var versionText: String {
        let info: [String: Any]? = Bundle.main.infoDictionary
        let short: String = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build: String = (info?["CFBundleVersion"] as? String) ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
    }

    private func content(size: CGSize) -> some View {
        let u: CGFloat = Theme.scale(for: size)
        let panelW: CGFloat = min(size.width * 0.8, 480.0 * u)
        return ZStack {
            DimBackdrop(opacity: 0.6)
            VStack(spacing: 10.0 * u) {
                Text("CREDITS")
                    .font(Theme.font(24.0 * u, weight: .heavy))
                    .foregroundColor(Theme.gold)
                creditLine("Artwork made with Google Flow (Nano Banana)", u: u)
                creditLine("Physics, rules and animations ported from the Python game", u: u)
                creditLine("Moroccan x Dutch lounge: emerald cloth, gold, walnut and zellige blue", u: u)
                Text(versionText)
                    .font(Theme.font(12.0 * u, weight: .medium))
                    .foregroundColor(Theme.gold.opacity(0.85))
                    .padding(.top, 2.0 * u)
                Button(action: onClose) {
                    Text("Close")
                }
                .buttonStyle(GoldButtonStyle(prominent: true, height: 42.0 * u, fontSize: 17.0 * u))
                .frame(width: 180.0 * u)
                .padding(.top, 4.0 * u)
            }
            .padding(20.0 * u)
            .frame(width: panelW)
            .goldPanel(cornerRadius: 20.0 * u, fillOpacity: 0.92, borderWidth: 2.0)
        }
        .frame(width: size.width, height: size.height)
    }

    private func creditLine(_ text: String, u: CGFloat) -> some View {
        return Text(text)
            .font(Theme.font(14.0 * u, weight: .medium))
            .foregroundColor(Theme.cream)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.8)
    }
}
