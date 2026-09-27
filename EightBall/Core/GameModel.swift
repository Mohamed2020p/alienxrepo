import Foundation
import Combine
import CoreGraphics
import SceneKit

/// Which full-screen layer the SwiftUI overlay shows.
enum ScreenPhase {
    case menu       // main menu over the 3D lounge
    case playing    // the HUD and the shot controls
    case paused     // pause menu
    case over       // game over
}

/// One of the seven balls a player still has to pot (or, at the end, the 8).
struct TargetBall: Identifiable, Equatable {
    let id: Int             // ball number 1...15
    var pocketed: Bool
}

/// What the HUD shows for one of the two players.
struct PlayerHUD: Equatable {
    var name: String                // "YOU" / "AI (medium)"
    var avatar: String              // image path inside Data/, e.g. "tex/avatar_you.png"
    var groupText: String           // "solids 1-7", "stripes 9-15", "open table"
    var targets: [TargetBall]       // empty while the table is open
    var active: Bool                // it is this player's turn
}

/// Everything the SwiftUI layer displays. The game (GameController) writes it, the views only read it.
@MainActor
final class GameModel: ObservableObject {
    @Published var screen: ScreenPhase = .menu
    @Published var players: [PlayerHUD] = [
        PlayerHUD(name: "YOU", avatar: "tex/avatar_you.png", groupText: "open table", targets: [], active: true),
        PlayerHUD(name: "AI", avatar: "tex/avatar_ai.png", groupText: "open table", targets: [], active: false)
    ]
    /// Big banner at the top ("YOUR SHOT", "AI is thinking...", "BALL IN HAND").
    /// (banner, canShoot, wrongBall, cameraLabel and guideLabel are written every frame by the game loop: the setters only publish a real change,
    /// otherwise SwiftUI would re-evaluate the whole overlay 60-120 times a second.)
    @Published private var bannerStore: String = ""
    var banner: String {
        get { return bannerStore }
        set { if bannerStore != newValue { bannerStore = newValue } }
    }
    /// Smaller line under the banner ("Foul: scratch. AI to shoot."); the game clears it after a few seconds.
    @Published var message: String = ""
    /// Huge centre text for a moment ("BREAK!", "YOU WIN!").
    @Published var shout: String = ""
    /// The shot controls (power bar, spin ball, fine aim) are only shown while the human can shoot.
    @Published var controlsVisible: Bool = false
    /// 0...1: how far the cue is drawn back.
    @Published var power: Double = 0
    /// Strike point on the cue ball, -1...1 each (x right, y up = top spin).
    @Published var spinX: Double = 0
    @Published var spinY: Double = 0
    /// False while the character is still walking to the shot: the power bar is greyed out.
    @Published private var canShootStore: Bool = false
    var canShoot: Bool {
        get { return canShootStore }
        set { if canShootStore != newValue { canShootStore = newValue } }
    }
    /// Ball in hand: the player drags the cue ball, a "Place" button is shown.
    @Published var placingBall: Bool = false
    /// True while the aim points at a ball that is not the player's.
    @Published private var wrongBallStore: Bool = false
    var wrongBall: Bool {
        get { return wrongBallStore }
        set { if wrongBallStore != newValue { wrongBallStore = newValue } }
    }
    @Published var fps: Int = 0
    @Published private var cameraLabelStore: String = "Behind the cue"
    var cameraLabel: String {
        get { return cameraLabelStore }
        set { if cameraLabelStore != newValue { cameraLabelStore = newValue } }
    }
    @Published private var guideLabelStore: String = "Guide 2"
    var guideLabel: String {
        get { return guideLabelStore }
        set { if guideLabelStore != newValue { guideLabelStore = newValue } }
    }
    @Published var gameOverTitle: String = ""
    @Published var gameOverSubtitle: String = ""
    @Published var youWon: Bool = false
}

/// What the views (and the gesture recognisers of the view controller) ask the game to do. Implemented by `GameController`.
@MainActor
protocol GameCommands: AnyObject {
    func startGame()
    func resumeGame()
    func pauseGame()
    func restartGame()
    func quitToMenu()

    /// The player drags the power bar: 0...1 (the character draws the cue back).
    func setPower(_ value: Double)
    /// The finger left the power bar: shoot with the current power (nothing happens under 3 %).
    func releasePower()
    /// The finger was dragged off / the shot was cancelled.
    func cancelPower()
    /// Fine aim: rotate the aim by this many radians (the fine-aim slider / buttons).
    func nudgeAim(_ radians: Double)
    /// Strike point on the cue ball, each -1...1.
    func setSpin(x: Double, y: Double)

    func cycleCamera()
    func cycleGuide()
    /// Ball in hand: put the cue ball where the ghost is.
    func confirmPlacement()

    /// One finger dragged on the 3D view: aims (or, while placing, moves the cue ball).
    func dragAim(dx: Double, dy: Double)
    /// Two fingers dragged: look around (orbit).
    func dragOrbit(dx: Double, dy: Double)
    func pinch(scale: Double)
    /// While placing the cue ball: the touch position in the SCNView (the ball follows the finger).
    func dragPlace(to point: CGPoint, in view: SCNView)

    /// A value in `GameSettings` changed (quality, volume ...): apply it.
    func settingsChanged()
}
