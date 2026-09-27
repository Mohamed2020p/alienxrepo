import SwiftUI
import Combine

/// The shot controls: a tall POWER bar on the right (drag down to draw the cue back, lift to shoot), the SPIN ball,
/// the FINE-AIM slider with its two nudge buttons, and the "Place ball" button while the cue ball is in hand.
@MainActor
struct ShotControlsView: View {
    @ObservedObject var model: GameModel
    let commands: GameCommands

    // power bar
    @State private var powerDragging: Bool = false
    @State private var powerValue: Double = 0.0
    @State private var powerOutside: Bool = false
    // spin ball
    @State private var spinX: Double
    @State private var spinY: Double
    // fine aim slider (-1 ... 1, springs back to 0)
    @State private var fineValue: Double = 0.0
    @State private var fineLast: Double = 0.0
    // hold-to-repeat on the < > buttons
    @State private var holdDirection: Double = 0.0
    @State private var holdTicks: Int = 0

    /// One shared 25 Hz ticker (a stored publisher would be re-created every time the parent redraws).
    private static let holdTimer: Publishers.Autoconnect<Timer.TimerPublisher> = Timer.publish(every: 0.04, on: RunLoop.main, in: RunLoop.Mode.common).autoconnect()

    /// Dragging the fine-aim slider to the right turns the aim to the right. The Python game does `aim -= radians(dx)`, so right = negative
    /// (angles are counter-clockwise seen from above).
    private let rightSign: Double = -1.0
    /// Radians per slider unit (the thumb travelling from the centre to the end = 1 unit).
    private let fineGain: Double = 0.02
    /// Radians per tap on the < > buttons.
    private let buttonStep: Double = 0.002

    init(model: GameModel, commands: GameCommands) {
        _model = ObservedObject(wrappedValue: model)
        self.commands = commands
        _spinX = State(initialValue: model.spinX)
        _spinY = State(initialValue: model.spinY)
    }

    var body: some View {
        GeometryReader { geo in
            layout(size: geo.size)
        }
    }

    // MARK: Layout

    private func layout(size: CGSize) -> some View {
        let u: CGFloat = Theme.scale(for: size)
        let barW: CGFloat = 60.0 * u
        let labelH: CGFloat = 18.0 * u
        let barH: CGFloat = max(120.0, min(size.height - 128.0 * u - labelH, 300.0 * u))
        let spinD: CGFloat = min(92.0 * u, size.height * 0.26)
        let fineW: CGFloat = min(size.width * 0.36, 330.0 * u)
        let showControls: Bool = model.controlsVisible && !model.placingBall
        return ZStack {
            if showControls {
                spinControl(diameter: spinD, u: u)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, barW + 22.0 * u)
                    .padding(.bottom, 6.0 * u)
                fineAim(width: fineW, u: u)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 8.0 * u)
                    .padding(.bottom, 6.0 * u)
                powerColumn(barW: barW, barH: barH, u: u)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 6.0 * u)
                    .padding(.bottom, 6.0 * u)
            }
            if model.placingBall {
                placeButton(u: u)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14.0 * u)
            }
        }
        .frame(width: size.width, height: size.height)
        .onReceive(ShotControlsView.holdTimer) { (_: Date) in
            holdTick()
        }
        .onDisappear {
            if powerDragging {
                powerDragging = false
                commands.cancelPower()
            }
            holdDirection = 0.0
        }
    }

    // MARK: Power bar

    private func powerColumn(barW: CGFloat, barH: CGFloat, u: CGFloat) -> some View {
        let enabled: Bool = model.canShoot
        let shown: Double = powerDragging ? powerValue : min(max(model.power, 0.0), 1.0)
        let pct: Int = Int((shown * 100.0).rounded())
        let fillColor: Color = powerFillColor(shown: shown, enabled: enabled)
        let track: RoundedRectangle = RoundedRectangle(cornerRadius: barW * 0.3, style: .continuous)
        let fillH: CGFloat = CGFloat(shown) * barH
        let handleY: CGFloat = fillH - 5.0 * u
        let labelText: String = (powerDragging && powerOutside) ? "CANCEL" : "POWER"
        let textColor: Color = enabled ? Theme.cream : Theme.cream.opacity(0.4)
        let ticks: [Double] = [0.25, 0.5, 0.75]
        return VStack(spacing: 4.0 * u) {
            Text(labelText)
                .font(Theme.font(11.0 * u))
                .foregroundColor(textColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: barW + 12.0 * u)
            ZStack(alignment: .top) {
                ZStack(alignment: .top) {
                    track.fill(Theme.midnight.opacity(enabled ? 0.82 : 0.6))
                    Rectangle()
                        .fill(fillColor)
                        .frame(width: barW, height: fillH)
                }
                .frame(width: barW, height: barH)
                .clipShape(track)
                .overlay(track.strokeBorder(enabled ? Theme.gold : Theme.gold.opacity(0.35), lineWidth: 2.0))

                ForEach(ticks, id: \.self) { (t: Double) in
                    Rectangle()
                        .fill(Theme.cream.opacity(0.35))
                        .frame(width: barW * 0.45, height: 1.5)
                        .offset(x: 0, y: CGFloat(t) * barH)
                }

                if enabled {
                    RoundedRectangle(cornerRadius: 4.0 * u, style: .continuous)
                        .fill(Theme.cream)
                        .frame(width: barW + 8.0 * u, height: 10.0 * u)
                        .overlay(RoundedRectangle(cornerRadius: 4.0 * u, style: .continuous).strokeBorder(Theme.midnight, lineWidth: 1.5))
                        .offset(x: 0, y: handleY)
                }

                if powerDragging {
                    Text("\(pct)%")
                        .font(.system(size: 15.0 * u, weight: .bold, design: .monospaced))
                        .foregroundColor(Theme.cream)
                        .padding(.horizontal, 6.0 * u)
                        .padding(.vertical, 2.0 * u)
                        .background(Capsule().fill(Theme.midnight.opacity(0.8)))
                        .offset(x: -(barW * 0.5 + 34.0 * u), y: fillH - 10.0 * u)
                }
            }
            .frame(width: barW, height: barH, alignment: .top)
            .contentShape(Rectangle())
            .gesture(powerGesture(barW: barW, barH: barH))
        }
    }

    private func powerFillColor(shown: Double, enabled: Bool) -> Color {
        if !enabled {
            return Color.gray.opacity(0.55)
        }
        if powerDragging && powerOutside {
            return Theme.delft
        }
        return Theme.powerColor(shown)
    }

    private func powerGesture(barW: CGFloat, barH: CGFloat) -> some Gesture {
        return DragGesture(minimumDistance: 0)
            .onChanged { (value: DragGesture.Value) in
                powerChanged(value, barW: barW, barH: barH)
            }
            .onEnded { (value: DragGesture.Value) in
                powerEnded(value, barW: barW)
            }
    }

    private func isOutside(_ value: DragGesture.Value, barW: CGFloat) -> Bool {
        let x: CGFloat = value.location.x
        return x < -70.0 || x > barW + 70.0
    }

    private func powerChanged(_ value: DragGesture.Value, barW: CGFloat, barH: CGFloat) {
        if !model.canShoot {
            return
        }
        let travel: CGFloat = max(barH * 0.92, 1.0)
        var v: Double = Double(value.translation.height / travel)
        v = min(max(v, 0.0), 1.0)
        powerDragging = true
        powerValue = v
        powerOutside = isOutside(value, barW: barW)
        commands.setPower(v)
    }

    private func powerEnded(_ value: DragGesture.Value, barW: CGFloat) {
        if !powerDragging {
            return
        }
        let outside: Bool = isOutside(value, barW: barW)
        powerDragging = false
        powerOutside = false
        powerValue = 0.0
        if outside {
            commands.cancelPower()
        } else {
            commands.releasePower()
        }
    }

    // MARK: Spin ball

    private func spinControl(diameter: CGFloat, u: CGFloat) -> some View {
        let r: CGFloat = diameter / 2.0
        let reach: CGFloat = r * 0.8
        let dotSize: CGFloat = diameter * 0.2
        let dx: CGFloat = CGFloat(model.spinX) * reach
        let dy: CGFloat = -CGFloat(model.spinY) * reach
        return VStack(spacing: 3.0 * u) {
            Text("SPIN")
                .font(Theme.font(11.0 * u))
                .foregroundColor(Theme.cream)
            ZStack {
                DataImage("tex/spin_ball.png", fit: true, fallback: Theme.cream)
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                DataImage("tex/dot.png", fit: true, fallback: Theme.orange)
                    .frame(width: dotSize, height: dotSize)
                    .clipShape(Circle())
                    .offset(x: dx, y: dy)
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
            .gesture(spinGesture(diameter: diameter))
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    resetSpin()
                }
            )
        }
    }

    private func spinGesture(diameter: CGFloat) -> some Gesture {
        return DragGesture(minimumDistance: 0)
            .onChanged { (value: DragGesture.Value) in
                spinChanged(value, diameter: diameter)
            }
    }

    private func spinChanged(_ value: DragGesture.Value, diameter: CGFloat) {
        let r: CGFloat = diameter / 2.0
        let reach: CGFloat = max(r * 0.8, 1.0)
        var nx: Double = Double((value.location.x - r) / reach)
        var ny: Double = Double((r - value.location.y) / reach)
        let len: Double = (nx * nx + ny * ny).squareRoot()
        if len > 1.0 {
            nx = nx / len
            ny = ny / len
        }
        spinX = nx
        spinY = ny
        commands.setSpin(x: nx, y: ny)
    }

    private func resetSpin() {
        spinX = 0.0
        spinY = 0.0
        commands.setSpin(x: 0.0, y: 0.0)
    }

    // MARK: Fine aim

    private func fineAim(width: CGFloat, u: CGFloat) -> some View {
        let btn: CGFloat = 34.0 * u
        let gap: CGFloat = 6.0 * u
        let trackW: CGFloat = max(width - 2.0 * btn - 2.0 * gap, 80.0)
        return VStack(alignment: .leading, spacing: 3.0 * u) {
            Text("FINE AIM")
                .font(Theme.font(11.0 * u))
                .foregroundColor(Theme.cream)
            HStack(spacing: gap) {
                nudgeButton(systemName: "chevron.left", direction: -1.0, size: btn, u: u)
                fineSlider(trackW: trackW, height: btn, u: u)
                nudgeButton(systemName: "chevron.right", direction: 1.0, size: btn, u: u)
            }
        }
    }

    private func fineSlider(trackW: CGFloat, height: CGFloat, u: CGFloat) -> some View {
        let thumb: CGFloat = height * 0.86
        let half: CGFloat = max((trackW - thumb) / 2.0, 1.0)
        return ZStack {
            Capsule().fill(Theme.midnight.opacity(0.8))
            Capsule().strokeBorder(Theme.gold, lineWidth: 1.5)
            Rectangle()
                .fill(Theme.cream.opacity(0.35))
                .frame(width: 1.5, height: height * 0.5)
            Circle()
                .fill(Theme.gold)
                .frame(width: thumb, height: thumb)
                .overlay(Circle().strokeBorder(Theme.midnight, lineWidth: 1.5))
                .offset(x: CGFloat(fineValue) * half, y: 0)
        }
        .frame(width: trackW, height: height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { (value: DragGesture.Value) in
                    fineChanged(value, half: half)
                }
                .onEnded { (_: DragGesture.Value) in
                    fineEnded()
                }
        )
    }

    private func fineChanged(_ value: DragGesture.Value, half: CGFloat) {
        var n: Double = Double(value.translation.width / half)
        n = min(max(n, -1.0), 1.0)
        let delta: Double = n - fineLast
        fineLast = n
        fineValue = n
        if delta != 0.0 {
            commands.nudgeAim(delta * fineGain * rightSign)
        }
    }

    private func fineEnded() {
        fineLast = 0.0
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            fineValue = 0.0
        }
    }

    private func nudgeButton(systemName: String, direction: Double, size: CGFloat, u: CGFloat) -> some View {
        return Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundColor(Theme.cream)
            .frame(width: size, height: size)
            .background(Circle().fill(Theme.midnight.opacity(0.8)))
            .overlay(Circle().strokeBorder(Theme.gold, lineWidth: 1.5))
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { (_: DragGesture.Value) in
                        holdBegan(direction)
                    }
                    .onEnded { (_: DragGesture.Value) in
                        holdDirection = 0.0
                        holdTicks = 0
                    }
            )
    }

    /// Touch down on a < > button: one step at once; the step repeats while the finger stays down.
    private func holdBegan(_ direction: Double) {
        if holdDirection == direction {
            return
        }
        holdDirection = direction
        holdTicks = 0
        commands.nudgeAim(direction * buttonStep * rightSign)
    }

    private func holdTick() {
        if holdDirection == 0.0 {
            return
        }
        holdTicks += 1
        if holdTicks > 8 {
            commands.nudgeAim(holdDirection * buttonStep * rightSign)
        }
    }

    // MARK: Ball in hand

    private func placeButton(u: CGFloat) -> some View {
        return VStack(spacing: 6.0 * u) {
            Text("Drag the cue ball, then confirm")
                .font(Theme.font(12.0 * u, weight: .semibold))
                .foregroundColor(Theme.cream)
                .padding(.horizontal, 10.0 * u)
                .padding(.vertical, 3.0 * u)
                .background(Capsule().fill(Theme.midnight.opacity(0.65)))
            Button(action: { commands.confirmPlacement() }) {
                Text("Place ball")
            }
            .buttonStyle(GoldButtonStyle(prominent: true, height: 46.0 * u, fontSize: 18.0 * u))
            .frame(width: 190.0 * u)
        }
    }
}
