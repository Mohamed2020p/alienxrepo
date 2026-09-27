import SwiftUI

/// The whole SwiftUI overlay. Everything that is not a button or a panel lets the touches fall through to the SCNView.
@MainActor
struct RootView: View {
    @ObservedObject var model: GameModel
    @ObservedObject var settings: GameSettings
    let commands: GameCommands

    @State private var showSettings: Bool = false
    @State private var showCredits: Bool = false

    init(model: GameModel, settings: GameSettings, commands: GameCommands) {
        _model = ObservedObject(wrappedValue: model)
        _settings = ObservedObject(wrappedValue: settings)
        self.commands = commands
    }

    private var showsHUD: Bool {
        return model.screen != ScreenPhase.menu
    }

    private var showsControls: Bool {
        if model.screen != ScreenPhase.playing {
            return false
        }
        return model.controlsVisible || model.placingBall
    }

    var body: some View {
        ZStack {
            if showsHUD {
                HUDView(model: model, settings: settings, commands: commands)
                    .transition(.opacity)
            }
            if showsControls {
                ShotControlsView(model: model, commands: commands)
                    .transition(.opacity)
            }
            screenLayer
            if showSettings {
                SettingsView(settings: settings, commands: commands, onClose: { showSettings = false })
                    .transition(.opacity)
            }
            if showCredits {
                CreditsView(onClose: { showCredits = false })
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.25), value: model.screen)
        .animation(.easeInOut(duration: 0.2), value: showSettings)
        .animation(.easeInOut(duration: 0.2), value: showCredits)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var screenLayer: some View {
        switch model.screen {
        case .menu:
            MainMenuView(settings: settings,
                         commands: commands,
                         onSettings: { showSettings = true },
                         onCredits: { showCredits = true })
                .transition(.opacity)
        case .playing:
            EmptyView()
        case .paused:
            PauseView(commands: commands, onSettings: { showSettings = true })
                .transition(.opacity)
        case .over:
            GameOverView(model: model, commands: commands)
                .transition(.opacity)
        }
    }
}
