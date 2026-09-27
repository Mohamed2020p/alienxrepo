import SwiftUI

/// One player's row: round avatar (gold ring on the active player), name, group text and the target ball icons.
@MainActor
struct PlayerRowView: View {
    let player: PlayerHUD
    let u: CGFloat

    var body: some View {
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 10.0 * u, style: .continuous)
        let fillColor: Color = player.active ? Theme.emerald.opacity(0.88) : Theme.midnight.opacity(0.62)
        let borderColor: Color = player.active ? Theme.gold : Theme.gold.opacity(0.25)
        return HStack(spacing: 7.0 * u) {
            avatar
            VStack(alignment: .leading, spacing: 2.0 * u) {
                Text(player.name)
                    .font(Theme.font(14.0 * u))
                    .foregroundColor(Theme.cream)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(player.groupText)
                    .font(Theme.font(11.0 * u, weight: .semibold))
                    .foregroundColor(Theme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if !player.targets.isEmpty {
                    HStack(spacing: 2.0 * u) {
                        ForEach(player.targets) { (t: TargetBall) in
                            DataImage("tex/icon_\(t.id).png", fit: true, fallback: Theme.cream.opacity(0.4))
                                .frame(width: 17.0 * u, height: 17.0 * u)
                                .opacity(t.pocketed ? 0.28 : 1.0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6.0 * u)
        .padding(.vertical, 5.0 * u)
        .frame(minHeight: 48.0 * u)
        .background(shape.fill(fillColor))
        .overlay(shape.strokeBorder(borderColor, lineWidth: 1.5))
    }

    private var avatar: some View {
        let s: CGFloat = 38.0 * u
        let ringSize: CGFloat = s * 1.2
        return ZStack {
            DataImage(player.avatar, fit: false, fallback: Theme.delft)
                .frame(width: s, height: s)
                .clipShape(Circle())
                .opacity(player.active ? 1.0 : 0.8)
            if player.active {
                DataImage("tex/ring.png", fit: true, fallback: Color.clear)
                    .frame(width: ringSize, height: ringSize)
            }
        }
        .frame(width: ringSize, height: ringSize)
    }
}

/// The heads-up display: players top-left, banner and message top-centre, big shout in the centre, fps, pause / camera / guide buttons.
@MainActor
struct HUDView: View {
    @ObservedObject var model: GameModel
    @ObservedObject var settings: GameSettings
    let commands: GameCommands

    init(model: GameModel, settings: GameSettings, commands: GameCommands) {
        _model = ObservedObject(wrappedValue: model)
        _settings = ObservedObject(wrappedValue: settings)
        self.commands = commands
    }

    var body: some View {
        GeometryReader { geo in
            layout(size: geo.size)
        }
    }

    private func layout(size: CGSize) -> some View {
        let u: CGFloat = Theme.scale(for: size)
        let sideW: CGFloat = min(212.0 * u, size.width * 0.31)
        return ZStack {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 6.0 * u) {
                    playersColumn(u: u)
                        .frame(width: sideW, alignment: .leading)
                    bannerColumn(u: u)
                        .frame(maxWidth: .infinity)
                    rightColumn(u: u)
                        .frame(width: sideW, alignment: .trailing)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8.0 * u)
            .padding(.top, 6.0 * u)

            shoutView(u: u)
                .allowsHitTesting(false)
        }
        .frame(width: size.width, height: size.height)
    }

    // MARK: Pieces

    private func playersColumn(u: CGFloat) -> some View {
        return VStack(alignment: .leading, spacing: 4.0 * u) {
            ForEach(0..<model.players.count, id: \.self) { (i: Int) in
                PlayerRowView(player: model.players[i], u: u)
            }
        }
        .allowsHitTesting(false)
    }

    private func bannerColumn(u: CGFloat) -> some View {
        return VStack(spacing: 4.0 * u) {
            if !model.banner.isEmpty {
                Text(model.banner)
                    .font(Theme.font(22.0 * u))
                    .foregroundColor(Theme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .padding(.horizontal, 16.0 * u)
                    .padding(.vertical, 5.0 * u)
                    .background(Capsule().fill(Theme.midnight.opacity(0.78)))
                    .overlay(Capsule().strokeBorder(Theme.gold, lineWidth: 1.5))
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .font(Theme.font(13.0 * u, weight: .semibold))
                    .foregroundColor(Theme.cream)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 12.0 * u)
                    .padding(.vertical, 4.0 * u)
                    .background(RoundedRectangle(cornerRadius: 10.0 * u, style: .continuous).fill(Theme.midnight.opacity(0.62)))
            }
            if model.wrongBall && model.screen == ScreenPhase.playing {
                Text("Not your ball")
                    .font(Theme.font(12.0 * u))
                    .foregroundColor(Theme.cream)
                    .padding(.horizontal, 12.0 * u)
                    .padding(.vertical, 3.0 * u)
                    .background(Capsule().fill(Theme.orange))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.banner)
        .animation(.easeOut(duration: 0.2), value: model.message)
        .allowsHitTesting(false)
    }

    private func rightColumn(u: CGFloat) -> some View {
        return VStack(alignment: .trailing, spacing: 6.0 * u) {
            HStack(spacing: 8.0 * u) {
                if settings.showFPS {
                    Text("\(model.fps) fps")
                        .font(.system(size: 12.0 * u, weight: .semibold, design: .monospaced))
                        .foregroundColor(Theme.cream)
                        .padding(.horizontal, 7.0 * u)
                        .padding(.vertical, 3.0 * u)
                        .background(Capsule().fill(Theme.midnight.opacity(0.6)))
                        .allowsHitTesting(false)
                }
                CircleIconButton(systemName: "pause.fill", size: 38.0 * u, action: { commands.pauseGame() })
            }
            labelButton(icon: "video.fill", title: model.cameraLabel, u: u, action: { commands.cycleCamera() })
            labelButton(icon: "scope", title: model.guideLabel, u: u, action: { commands.cycleGuide() })
        }
    }

    private func labelButton(icon: String, title: String, u: CGFloat, action: @escaping () -> Void) -> some View {
        return Button(action: action) {
            HStack(spacing: 5.0 * u) {
                Image(systemName: icon)
                    .font(.system(size: 11.0 * u, weight: .bold))
                Text(title)
                    .font(Theme.font(11.0 * u, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundColor(Theme.cream)
            .padding(.horizontal, 9.0 * u)
            .padding(.vertical, 7.0 * u)
            .background(Capsule().fill(Theme.midnight.opacity(0.72)))
            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.8), lineWidth: 1.0))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func shoutView(u: CGFloat) -> some View {
        return ZStack {
            if !model.shout.isEmpty {
                Text(model.shout)
                    .font(Theme.font(64.0 * u, weight: .heavy))
                    .foregroundColor(Theme.gold)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .shadow(color: Color.black.opacity(0.7), radius: 0, x: 0, y: 3.0 * u)
                    .padding(.horizontal, 24.0 * u)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: model.shout)
    }
}
