import SwiftUI

/// Settings overlay (from the main menu and from the pause menu). Every change ends with `commands.settingsChanged()`.
@MainActor
struct SettingsView: View {
    @ObservedObject var settings: GameSettings
    let commands: GameCommands
    let onClose: () -> Void

    init(settings: GameSettings, commands: GameCommands, onClose: @escaping () -> Void) {
        _settings = ObservedObject(wrappedValue: settings)
        self.commands = commands
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geo in
            content(size: geo.size)
        }
    }

    // MARK: Bindings (write, then tell the game)

    private var sensitivityBinding: Binding<Double> {
        return Binding<Double>(
            get: { return settings.sensitivity },
            set: { (newValue: Double) in
                settings.sensitivity = newValue
                commands.settingsChanged()
            }
        )
    }

    private var volumeBinding: Binding<Double> {
        return Binding<Double>(
            get: { return settings.volume },
            set: { (newValue: Double) in
                settings.volume = newValue
                commands.settingsChanged()
            }
        )
    }

    private var guideBinding: Binding<Bool> {
        return Binding<Bool>(
            get: { return settings.aimGuide },
            set: { (newValue: Bool) in
                settings.aimGuide = newValue
                commands.settingsChanged()
            }
        )
    }

    private var hapticsBinding: Binding<Bool> {
        return Binding<Bool>(
            get: { return settings.haptics },
            set: { (newValue: Bool) in
                settings.haptics = newValue
                commands.settingsChanged()
            }
        )
    }

    private var fpsBinding: Binding<Bool> {
        return Binding<Bool>(
            get: { return settings.showFPS },
            set: { (newValue: Bool) in
                settings.showFPS = newValue
                commands.settingsChanged()
            }
        )
    }

    private func selectQuality(_ q: Quality) {
        settings.quality = q
        commands.settingsChanged()
    }

    private func selectDifficulty(_ d: Difficulty) {
        settings.difficulty = d
        commands.settingsChanged()
    }

    private func qualityDescription(_ q: Quality) -> String {
        switch q {
        case .low:
            return "Fastest, no shadows"
        case .medium:
            return "Balanced"
        case .high:
            return "Real shadows + reflections"
        case .ultra:
            return "Sharpest, 120 fps on capable devices"
        }
    }

    // MARK: Layout

    private func content(size: CGSize) -> some View {
        let u: CGFloat = Theme.scale(for: size)
        let panelW: CGFloat = min(size.width * 0.94, 780.0 * u)
        let panelH: CGFloat = min(size.height * 0.94, 480.0 * u)
        let pad: CGFloat = 16.0 * u
        return ZStack {
            DimBackdrop(opacity: 0.6)
            VStack(spacing: 8.0 * u) {
                HStack {
                    Text("SETTINGS")
                        .font(Theme.font(24.0 * u, weight: .heavy))
                        .foregroundColor(Theme.gold)
                    Spacer()
                    Button(action: onClose) {
                        Text("Done")
                    }
                    .buttonStyle(GoldButtonStyle(prominent: true, height: 36.0 * u, fontSize: 16.0 * u))
                    .frame(width: 100.0 * u)
                }
                ScrollView(.vertical, showsIndicators: true) {
                    HStack(alignment: .top, spacing: 18.0 * u) {
                        qualityColumn(u: u)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        optionsColumn(u: u)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .padding(.bottom, 4.0 * u)
                }
            }
            .padding(pad)
            .frame(width: panelW, height: panelH)
            .goldPanel(cornerRadius: 20.0 * u, fillOpacity: 0.93, borderWidth: 2.0)
        }
        .frame(width: size.width, height: size.height)
    }

    private func sectionTitle(_ text: String, u: CGFloat) -> some View {
        return Text(text)
            .font(Theme.font(12.0 * u))
            .foregroundColor(Theme.gold)
            .padding(.top, 2.0 * u)
    }

    private func qualityColumn(u: CGFloat) -> some View {
        return VStack(alignment: .leading, spacing: 6.0 * u) {
            sectionTitle("GRAPHICS QUALITY", u: u)
            ForEach(Quality.allCases) { (q: Quality) in
                qualityRow(q, u: u)
            }
        }
    }

    private func qualityRow(_ q: Quality, u: CGFloat) -> some View {
        let selected: Bool = settings.quality == q
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 10.0 * u, style: .continuous)
        return Button(action: { selectQuality(q) }) {
            HStack(spacing: 10.0 * u) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18.0 * u, weight: .semibold))
                    .foregroundColor(selected ? Theme.gold : Theme.cream.opacity(0.6))
                VStack(alignment: .leading, spacing: 1.0 * u) {
                    Text(q.title)
                        .font(Theme.font(15.0 * u))
                        .foregroundColor(Theme.cream)
                    Text(qualityDescription(q))
                        .font(Theme.font(11.0 * u, weight: .medium))
                        .foregroundColor(Theme.cream.opacity(0.7))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10.0 * u)
            .padding(.vertical, 7.0 * u)
            .frame(maxWidth: .infinity)
            .background(shape.fill(selected ? Theme.emerald.opacity(0.85) : Theme.midnight.opacity(0.5)))
            .overlay(shape.strokeBorder(selected ? Theme.gold : Theme.gold.opacity(0.25), lineWidth: 1.5))
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func optionsColumn(u: CGFloat) -> some View {
        let sensText: String = String(format: "%.1fx", settings.sensitivity)
        let volText: String = "\(Int((settings.volume * 100.0).rounded()))%"
        return VStack(alignment: .leading, spacing: 8.0 * u) {
            sectionTitle("DIFFICULTY", u: u)
            HStack(spacing: 6.0 * u) {
                ForEach(Difficulty.allCases) { (d: Difficulty) in
                    PillChoice(title: d.title,
                               selected: settings.difficulty == d,
                               height: 32.0 * u,
                               fontSize: 14.0 * u,
                               action: { selectDifficulty(d) })
                }
            }
            sliderRow(title: "Touch sensitivity", valueText: sensText, binding: sensitivityBinding, low: 0.3, high: 2.0, u: u)
            sliderRow(title: "Volume", valueText: volText, binding: volumeBinding, low: 0.0, high: 1.0, u: u)
            toggleRow(title: "Aim guide", binding: guideBinding, u: u)
            toggleRow(title: "Haptics", binding: hapticsBinding, u: u)
            toggleRow(title: "Show FPS", binding: fpsBinding, u: u)
        }
    }

    private func sliderRow(title: String, valueText: String, binding: Binding<Double>, low: Double, high: Double, u: CGFloat) -> some View {
        return VStack(alignment: .leading, spacing: 2.0 * u) {
            HStack {
                Text(title)
                    .font(Theme.font(14.0 * u, weight: .semibold))
                    .foregroundColor(Theme.cream)
                Spacer()
                Text(valueText)
                    .font(.system(size: 13.0 * u, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.gold)
            }
            Slider(value: binding, in: low...high)
                .tint(Theme.gold)
        }
    }

    private func toggleRow(title: String, binding: Binding<Bool>, u: CGFloat) -> some View {
        return HStack {
            Text(title)
                .font(Theme.font(14.0 * u, weight: .semibold))
                .foregroundColor(Theme.cream)
            Spacer()
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: Theme.gold))
        }
    }
}
