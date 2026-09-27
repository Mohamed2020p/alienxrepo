# EIGHT BALL - native iOS 8-ball pool (Swift 5, SceneKit + SwiftUI + AVFoundation)

The iPhone / iPad version of the Python game in `../pool_game` (Panda3D): the same 3D lounge (Moroccan x Dutch theme), the same table, balls,
cues and physics, the same white-ninja player and orange-tee AI opponent with the same baked animations and poses (idle, walk, lean over the
table, stroke, cheer, lose), the same 8-ball rules and AI (easy / medium / hard), the same aim guide (thin white line, ghost ball, red X on a
wrong ball), the same quality presets, the same sounds. **No neon anywhere**: the look is the lounge's - emerald cloth, gold, walnut, zellige blue.

IMPORTANT: this project is authored on Windows - **nothing has been compiled**. Every file must compile the first time: explicit types, simple
expressions (split long ones), no third-party dependencies, only public Apple APIs of iOS 16, `import` everything you use, `@MainActor` on
everything that touches UI or SceneKit. `python tools/check_swift.py --symbols` (tree-sitter) must report 0 syntax problems and 0 unknown symbols.
Target: iOS 16+, iPhone and iPad, landscape only, Swift language mode 5.

```
8balliosfiles/
  bitrise.yaml            unsigned IPA workflow (`build_ipa`) + simulator unit tests (`test`)
  project.yml             XcodeGen spec  -> EightBall.xcodeproj  (Bitrise generates it; tools/gen_xcodeproj.py writes a committed fallback)
  EightBall/
    App/        AppDelegate.swift, GameViewController.swift                                        (UI agent)
    Core/       Settings.swift, GameModel.swift (lead, FINAL)   GameRandom.swift PoolPhysics.swift PoolRules.swift PoolAI.swift (logic agent)
    Scene/      DataStore, MeshKit, PoolScene, BallView, ManAssets, Person, Shooter, CameraRig, AimGuide     (lead)
    Game/       GameController.swift, Haptics.swift                                                (lead)
    Audio/      AudioManager.swift                                                                 (lead)
    UI/         Theme, RootView, MainMenuView, HUDView, ShotControlsView, PauseView, SettingsView, GameOverView ...  (UI agent)
    Resources/  Data/ (exported assets, folder reference)   Audio/ (wav, folder reference)   Assets.xcassets   Info.plist
  EightBallTests/  XCTest: physics, rules and AI tests + golden vectors made by the Python game            (logic agent)
  tools/          export_ios_data.py (Python game -> Resources), gen_xcodeproj.py, check_swift.py, check_calls.py, check_members.py
  docs/ARCHITECTURE.md
```

## Conventions
* **Game coordinates** (physics, models, animation data - identical to the Python game): metres, **X along the long side, Y along the short side, Z up**,
  table centre at the origin, cloth top at z = `tableHeight` (0.80) above the floor (z = 0). SceneKit is Y-up, so `PoolScene` owns a node `gameRoot`
  rotated -90 degrees about X: **everything in the scene is a child of `gameRoot` and uses game coordinates** (positions, `look(at:)`, lights, camera).
  Never convert coordinates by hand.
* Angles in radians; a shot angle `a` points along `(cos a, sin a)` in game X/Y. The man faces -Y at heading 0; heading in degrees (CCW seen from above).
* `Double` for the physics and rules, `Float`/`simd` in SceneKit code.
* Everything runs on the main thread (`@MainActor`); the frame loop is `SCNSceneRendererDelegate.renderer(_:updateAtTime:)` in `GameController`.
* No third-party code, no `print` in per-frame paths, no global mutable state except what is named here.
* File / type names are unique in the module (duplicate top-level names fail to compile). Prefix private helpers with their file's topic.

## Resources (exported by tools/export_ios_data.py, see its docstring)
`Data/` (folder reference, read with `DataStore`): `models.bin/json` (table, lamp, cue, chalk triangle soups), `ninja.bin/json` (mask, hood, headband, sword),
`man.bin/json` (the man's animation frames), `man/man_tex_*.jpg`, `skins/variants.json` + prints + hair, `tex/*.png|jpg` (cloth, wood, rug, cue wraps,
ball textures `ball_0..15.jpg`, HUD ball icons `icon_1..15.png`, `icon_cue.png`, avatars `avatar_you.png` / `avatar_ai.png`, `ring.png`, `emblem.png`, `blob.png`, `env.png`),
`art/*.jpg` (posters, `menu_art.jpg`, `logo_wide.jpg`). `Audio/` (folder reference): every sound as `name.wav` (click_soft_1 ... pocket_1 ... room ...).

## Shared contracts (final - do not change signatures)

### `Core/Settings.swift`: `Quality`, `Difficulty`, `QualityProfile`, `GameSettings` (ObservableObject, persisted)
### `Core/GameModel.swift`: `ScreenPhase`, `TargetBall`, `PlayerHUD`, `GameModel` (what the HUD shows), `GameCommands` (what the UI asks for)
### `Scene/DataStore.swift`: `DataStore.image(_:)`, `.data(_:)`, `.json(_:)`, `.url(_:)`, `.audioRoot`

### Physics / rules / AI (`Core/PoolPhysics.swift`, `PoolRules.swift`, `PoolAI.swift`) - a faithful port of `pg_physics.py`, `pg_rules.py`, `pg_ai.py`
```swift
enum PoolConst { static let R: Double = 0.02858 ; static let HL: Double = 1.27 ; static let HW: Double = 0.635 ; static let headX: Double ; static let footX: Double ...
                 static let cornerPocket: (Double, Double) ; static let sidePocketY: Double }   // every constant of the Python module, same values
enum BallState { case active, pocketed }
final class Ball { let id: Int; var x, y, vx, vy, wx, wy, wz: Double; var state: BallState; var pocket: Int?; var dropSpeed: Double; var dropDirX, dropDirY: Double }
enum PhysicsEvent { case cueHit(id: Int, speed: Double); case ballBall(a: Int, b: Int, speed: Double); case cushion(id: Int, speed: Double)
                    case pocket(id: Int, pocket: Int, speed: Double) }
struct BallSnapshot { ... }                       // cheap copy of every ball's state
final class Physics {
    var balls: [Ball]                             // 16, index == id (0 = cue ball)
    var events: [PhysicsEvent]                    // the caller drains it: `physics.events.removeAll()`
    init(empty: Bool = false)
    func rack(seed: UInt64?)
    func resetCue(x: Double, y: Double)
    func placeBall(_ i: Int, x: Double, y: Double)            // also revives a pocketed ball
    func isFree(x: Double, y: Double, radius: Double = PoolConst.R, ignore: Int? = nil) -> Bool
    func activeBalls() -> [Ball]
    func moving() -> Bool
    func snapshot() -> BallSnapshot ; func restore(_ s: BallSnapshot)
    func strike(angle: Double, speed: Double, side: Double, top: Double)
    func step(_ dt: Double)
}
struct ShotOutcome { var firstHit: Int?; var pocketed: [Int]; var cuePocketed: Bool; var railAfterContact: Bool; var final: [(id: Int, x: Double, y: Double)]; var time: Double }
final class ShotSim { init(snapshot:angle:speed:side:top:maxTime:dt:) ; func advance(_ steps: Int) ; func run() ; var outcome: ShotOutcome }
func simulateShot(_ s: BallSnapshot, angle: Double, speed: Double, side: Double, top: Double, maxTime: Double = 20, dt: Double = 1.0/120.0) -> ShotOutcome

struct ShotResult { var foul: Bool; var reason: String; var pocketed: [Int]; var nextPlayer: Int; var ballInHand: Bool; var respot: [(id: Int, x: Double, y: Double)]
                    var gameOver: Bool; var winner: Int?; var groupsAssigned: Bool }
final class EightBallRules {
    var current: Int; var groups: [String?]            // index = player 0/1: "solid", "stripe" or nil (open table)
    var breakShot: Bool; var ballInHand: Bool
    var kitchenOnly: Bool; var winner: Int?; var message: String
    init(); func reset(firstPlayer: Int = 0)
    func legalTargets(player: Int, physics: Physics) -> Set<Int>
    func beginShot(); func onEvent(_ e: PhysicsEvent); func endShot(physics: Physics) -> ShotResult
}
struct AIShot { var angle: Double; var speed: Double; var side: Double; var top: Double; var place: (x: Double, y: Double)? }
final class AIPlanner {
    init(difficulty: Difficulty)
    func start(physics: Physics, rules: EightBallRules, player: Int, seed: UInt64?)
    func step(budget: Double) -> AIShot?          // call once per frame; nil while it is still thinking (budget in seconds of work)
}
```

### The game controller (`Game/GameController.swift`, lead) - what `GameViewController` uses
```swift
@MainActor final class GameController: NSObject, GameCommands {      // the frame loop is a CADisplayLink
    let model: GameModel
    let settings: GameSettings
    init(settings: GameSettings)
    func attach(to view: SCNView)        // builds/attaches the 3D scene, sets delegate, antialiasing, preferred FPS
    // + every `GameCommands` method
}
```
`GameViewController` (UI agent): full-screen `SCNView` (background dark), a `UIHostingController(rootView: RootView(...))` on top with a clear background,
gesture recognisers on the SCNView: one-finger pan -> `dragAim(dx:dy:)` (deltas since the last callback, in points), and while `model.placingBall` also
`dragPlace(to:in:)`; two-finger pan -> `dragOrbit`; pinch -> `pinch(scale:)` (ratio since the last callback). Non-interactive SwiftUI layers use
`.allowsHitTesting(false)` so touches fall through to the SCNView.

## The UI (UI agent)
Landscape. Gold `#D9A93A` / emerald `#0B4B2A` / midnight `#0A1622` / cream `#F3EBD8` / Dutch orange `#F26B1D` / delft blue `#2E5FA8`. No neon, no glow effects.
* Main menu over the 3D lounge (the SCNView is visible behind, slowly orbiting): logo (`art/logo_wide.jpg`), Play, difficulty picker, Settings, credits.
* HUD: two player rows top-left (round avatar with a gold ring on the active player, name, group text, the row of target ball icons - potted ones dimmed to 28 %),
  banner + message top-centre, big shout in the centre, fps top-right (if enabled).
* Shot controls (`controlsVisible`): **a vertical power bar on the right** (drag down to draw the cue back, release to shoot; greyed while `!canShoot`), a spin ball
  (cue ball picture with a red dot, drag inside it) and a **fine-aim slider** along the bottom-left; camera and guide buttons; pause button.
* Ball in hand: banner + a "Place ball" button (`confirmPlacement()`).
* Settings screen: graphics quality (low / medium / high / ultra with a one-line description of each), difficulty, touch sensitivity slider, volume, aim guide toggle,
  haptics toggle, show FPS toggle. Pause menu: Resume, Restart, Settings, Main menu. Game over: title, subtitle, Play again, Main menu.
* Credits screen: generated art credit ("Artwork made with Google Flow - Nano Banana"), the Python-game lineage.

## Physics contract (same as Python)
Rolling / sliding with spin, ball-ball e = 0.95, cushions with tangential friction, **pockets: a ball whose centre gets within the capture radius of a pocket
centre drops in, at any speed - no bouncing back out**; cushion ends are cut back, knuckle radius 0.002. Fixed step 1/120 s.
