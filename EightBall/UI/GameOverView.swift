import SwiftUI

/// Game over: title ("YOU WIN!"), subtitle, Play again, Main menu.
@MainActor
struct GameOverView: View {
    @ObservedObject var model: GameModel
    let commands: GameCommands

    init(model: GameModel, commands: GameCommands) {
        _model = ObservedObject(wrappedValue: model)
        self.commands = commands
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
    }

    private func content(size: CGSize) -> some View {
        let u: CGFloat = Theme.scale(for: size)
        let panelW: CGFloat = min(size.width * 0.7, 420.0 * u)
        let titleColor: Color = model.youWon ? Theme.gold : Theme.orange
        let title: String = model.gameOverTitle.isEmpty ? (model.youWon ? "YOU WIN!" : "GAME OVER") : model.gameOverTitle
        return ZStack {
            DimBackdrop(opacity: 0.55)
            VStack(spacing: 10.0 * u) {
                DataImage("tex/icon_8.png", fit: true, fallback: Color.clear)
                    .frame(width: 44.0 * u, height: 44.0 * u)
                Text(title)
                    .font(Theme.font(32.0 * u, weight: .heavy))
                    .foregroundColor(titleColor)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .multilineTextAlignment(.center)
                if !model.gameOverSubtitle.isEmpty {
                    Text(model.gameOverSubtitle)
                        .font(Theme.font(15.0 * u, weight: .medium))
                        .foregroundColor(Theme.cream)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                Button(action: { commands.startGame() }) {
                    Text("Play again")
                }
                .buttonStyle(GoldButtonStyle(prominent: true, height: 46.0 * u, fontSize: 19.0 * u))
                .padding(.top, 6.0 * u)
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
