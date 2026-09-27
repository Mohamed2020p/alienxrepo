import SwiftUI

/// Main menu: a semi-transparent midnight panel over the 3D lounge (the SCNView shows through).
@MainActor
struct MainMenuView: View {
    @ObservedObject var settings: GameSettings
    let commands: GameCommands
    let onSettings: () -> Void
    let onCredits: () -> Void

    init(settings: GameSettings, commands: GameCommands, onSettings: @escaping () -> Void, onCredits: @escaping () -> Void) {
        _settings = ObservedObject(wrappedValue: settings)
        self.commands = commands
        self.onSettings = onSettings
        self.onCredits = onCredits
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
    }

    private func content(size: CGSize) -> some View {
        let u: CGFloat = Theme.scale(for: size)
        let panelW: CGFloat = min(size.width * 0.92, 780.0 * u)
        let pad: CGFloat = 16.0 * u
        let gap: CGFloat = 18.0 * u
        let inner: CGFloat = panelW - 2.0 * pad
        let leftW: CGFloat = (inner - gap) * 0.56
        let rightW: CGFloat = (inner - gap) - leftW
        return ZStack {
            HStack(alignment: .center, spacing: gap) {
                leftColumn(width: leftW, u: u)
                rightColumn(width: rightW, u: u)
            }
            .padding(pad)
            .frame(width: panelW)
            .goldPanel(cornerRadius: 22.0 * u, fillOpacity: 0.72, borderWidth: 2.0)
        }
        .frame(width: size.width, height: size.height)
    }

    private func leftColumn(width: CGFloat, u: CGFloat) -> some View {
        let logoH: CGFloat = width * 460.0 / 1376.0
        let corner: RoundedRectangle = RoundedRectangle(cornerRadius: 12.0 * u, style: .continuous)
        return VStack(spacing: 8.0 * u) {
            ZStack {
                DataImage("art/logo_wide.jpg", fit: false, fallback: Theme.midnight)
                    .frame(width: width, height: logoH)
                    .clipped()
                if DataStore.image("art/logo_wide.jpg") == nil {
                    Text("8 BALL POOL")
                        .font(Theme.font(30.0 * u, weight: .heavy))
                        .foregroundColor(Theme.gold)
                }
            }
            .frame(width: width, height: logoH)
            .clipShape(corner)
            .overlay(corner.strokeBorder(Theme.gold.opacity(0.7), lineWidth: 1.2))

            Text("Moroccan x Dutch lounge  -  you against the house")
                .font(Theme.font(11.0 * u, weight: .medium))
                .foregroundColor(Theme.cream.opacity(0.75))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(width: width)
    }

    private func rightColumn(width: CGFloat, u: CGFloat) -> some View {
        return VStack(spacing: 10.0 * u) {
            Button(action: { commands.startGame() }) {
                Text("PLAY")
            }
            .buttonStyle(GoldButtonStyle(prominent: true, height: 50.0 * u, fontSize: 22.0 * u))

            VStack(spacing: 4.0 * u) {
                Text("DIFFICULTY")
                    .font(Theme.font(11.0 * u))
                    .foregroundColor(Theme.gold)
                HStack(spacing: 6.0 * u) {
                    ForEach(Difficulty.allCases) { (d: Difficulty) in
                        PillChoice(title: d.title,
                                   selected: settings.difficulty == d,
                                   height: 32.0 * u,
                                   fontSize: 14.0 * u,
                                   action: { selectDifficulty(d) })
                    }
                }
            }

            HStack(spacing: 8.0 * u) {
                Button(action: onSettings) {
                    Text("Settings")
                }
                .buttonStyle(GoldButtonStyle(prominent: false, height: 38.0 * u, fontSize: 14.0 * u))
                Button(action: onCredits) {
                    Text("Credits")
                }
                .buttonStyle(GoldButtonStyle(prominent: false, height: 38.0 * u, fontSize: 14.0 * u))
            }
        }
        .frame(width: width)
    }

    private func selectDifficulty(_ d: Difficulty) {
        settings.difficulty = d
        commands.settingsChanged()
    }
}
