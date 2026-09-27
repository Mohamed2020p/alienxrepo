import SwiftUI

/// Pause menu: Resume, Restart, Settings, Main menu.
@MainActor
struct PauseView: View {
    let commands: GameCommands
    let onSettings: () -> Void

    init(commands: GameCommands, onSettings: @escaping () -> Void) {
        self.commands = commands
        self.onSettings = onSettings
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
    }

    private func content(size: CGSize) -> some View {
        let u: CGFloat = Theme.scale(for: size)
        let panelW: CGFloat = min(size.width * 0.7, 380.0 * u)
        return ZStack {
            DimBackdrop(opacity: 0.5)
            VStack(spacing: 10.0 * u) {
                Text("PAUSED")
                    .font(Theme.font(26.0 * u, weight: .heavy))
                    .foregroundColor(Theme.gold)
                    .padding(.bottom, 2.0 * u)
                Button(action: { commands.resumeGame() }) {
                    Text("Resume")
                }
                .buttonStyle(GoldButtonStyle(prominent: true, height: 46.0 * u, fontSize: 19.0 * u))
                HStack(spacing: 8.0 * u) {
                    Button(action: { commands.restartGame() }) {
                        Text("Restart")
                    }
                    .buttonStyle(GoldButtonStyle(prominent: false, height: 40.0 * u, fontSize: 15.0 * u))
                    Button(action: onSettings) {
                        Text("Settings")
                    }
                    .buttonStyle(GoldButtonStyle(prominent: false, height: 40.0 * u, fontSize: 15.0 * u))
                }
                Button(action: { commands.quitToMenu() }) {
                    Text("Main menu")
                }
                .buttonStyle(GoldButtonStyle(prominent: false, height: 40.0 * u, fontSize: 15.0 * u))
            }
            .padding(20.0 * u)
            .frame(width: panelW)
            .goldPanel(cornerRadius: 20.0 * u, fillOpacity: 0.9, borderWidth: 2.0)
        }
        .frame(width: size.width, height: size.height)
    }
}
