# 8 Ball Pool - native iOS

A native iPhone / iPad (landscape) version of the Python 8-ball game in `../pool_game`: the same Moroccan x Dutch lounge (emerald cloth, gold, walnut,
zellige blue - no neon), the same table, balls and cues, the same white-ninja player and orange-tee AI opponent with the same baked animations,
the same 8-ball rules and AI (easy / medium / hard), the same aim guide and quality presets, the same sounds.

Swift 5, iOS 16+, SceneKit for the 3D scene, SwiftUI for the menus and the HUD, AVFoundation for the audio, CoreHaptics / UIKit feedback for the haptics.
No third-party code. See `docs/ARCHITECTURE.md` for the module contracts.

> The project was written on Windows without a Swift compiler. `python tools/check_swift.py --symbols`, `tools/check_calls.py` and
> `tools/check_members.py` are static checkers that catch syntax errors, unknown symbols and wrong call labels; the first real compile happens on Bitrise.

## Build

### Bitrise (recommended)
`bitrise.yaml` has two workflows:
* `build_ipa` - generates the Xcode project with XcodeGen (`project.yml`), archives an unsigned Release build and deploys `EightBall.ipa`
  (sign it afterwards, e.g. with a sideloading tool of your choice). If XcodeGen is not available the committed `EightBall.xcodeproj` is used.
* `test` - generates the project and runs the physics / rules / AI unit tests (`EightBallTests`) on an iPhone simulator.

### XcodeGen
```
brew install xcodegen
xcodegen generate --spec project.yml      # writes EightBall.xcodeproj
open EightBall.xcodeproj
```

### Fallback without XcodeGen
```
python tools/gen_xcodeproj.py             # writes EightBall.xcodeproj/project.pbxproj (walks every .swift file under EightBall/)
```
Re-run it whenever you add or remove a Swift file. Keep it consistent with `project.yml` (same target, same settings).

## How the assets are produced
* `python tools/export_ios_data.py [path to pool_game]` packs the Python game's assets into `EightBall/Resources/Data` (models, the man's animation
  frames, textures, ball icons, avatars, skins, posters) and `EightBall/Resources/Audio` (every sound as `.wav`).
* `python tools/make_ios_art.py` builds the asset catalog (app icon, launch logo, accent and launch colours) and the menu logo from the pictures in
  `art_raw/`, which were made with Google Flow (Nano Banana).
* Both folders under `Resources/` are added to the app as folder references and read at run time with `DataStore` (images, JSON, binary data).

## Controls (iPhone / iPad)
| Gesture | What it does |
| --- | --- |
| One finger drag on the table | Aim (left / right turns the cue; sensitivity is in Settings) |
| Two finger drag | Look around (orbit the camera) |
| Pinch | Zoom |
| POWER bar (right edge): drag down, lift the finger | Draw the cue back, release to shoot. Slide the finger sideways off the bar before lifting to cancel; under 3 % nothing happens |
| SPIN ball (bottom right): drag inside it, double tap to centre | Choose the strike point on the cue ball |
| FINE AIM slider (bottom left) and the `<` `>` buttons | Tiny aim corrections; the slider springs back to the middle, the buttons nudge 0.002 rad (hold to repeat) |
| Camera / Guide buttons (top right) | Cycle the camera view / the aim-guide level |
| Ball in hand | Drag the cue ball where you want it, then tap "Place ball" |
| Pause button (top right) | Pause menu: Resume, Restart, Settings, Main menu. The game also pauses when the app leaves the foreground |

## Folder layout
```
8balliosfiles/
  bitrise.yaml, project.yml          CI workflows, XcodeGen spec
  README.md, docs/ARCHITECTURE.md
  art_raw/                           source pictures made with Google Flow (Nano Banana)
  EightBall/
    App/         AppDelegate, GameViewController (SCNView + SwiftUI overlay + touch gestures)
    Core/        Settings, GameModel (what the UI shows / asks), GameRandom, PoolPhysics, PoolRules, PoolAI
    Scene/       DataStore, MeshKit, PoolScene, BallView, ManAssets, Person, Shooter, CameraRig, AimGuide ...
    Game/        GameController (frame loop, turns, shots), Haptics
    Audio/       AudioManager
    UI/          Theme, RootView, MainMenuView, HUDView, ShotControlsView, PauseView, SettingsView, GameOverView, CreditsView
    Resources/   Data/ (exported assets), Audio/ (wav), Assets.xcassets, Info.plist
  EightBallTests/                    XCTest: physics, rules, AI and golden vectors made by the Python game
  tools/                             export_ios_data.py, make_ios_art.py, gen_xcodeproj.py, check_swift.py, check_calls.py, check_members.py
```

## Differences from the Python game
* Touch controls instead of mouse and keyboard: a drag on the table replaces mouse aiming, the power bar replaces holding Space / the left button,
  the on-screen spin ball replaces the arrow keys, the fine-aim slider and buttons replace A / D, and two-finger drag / pinch replace right-drag / wheel.
* No free-walk mode (walking around the lounge with the keyboard): the camera can orbit and zoom around the table, that is all.
* Settings (quality, difficulty, sensitivity, volume, aim guide, haptics, FPS counter) live in an in-game settings screen and are saved in `UserDefaults`
  instead of `settings.json`; haptics are new.
* Quality presets keep the same table as `pg_settings.py`; "Ultra" asks for 120 fps on devices that support it.

## Credits
Artwork made with Google Flow (Nano Banana). Physics, rules and animations ported from the Python game.

## If something looks wrong on the first run

The project has never been compiled or run on a device (it was written on Windows); these are the known switches:

| Symptom | Fix |
|---|---|
| Textures / ball numbers upside down or mirrored | flip `MeshKit.flipV` in `EightBall/Scene/MeshKit.swift` |
| Whole scene looks pale / washed out | add `SCNDisableLinearSpaceRendering = YES` to `EightBall/Resources/Info.plist` |
| Dragging on the table does not aim | the SwiftUI overlay is eating touches: wrap the hosting view in a `UIView` whose `hitTest` returns nil when the hit view is the container itself (`App/GameViewController.swift`) |
| Frame rate low on an older iPhone | Settings > Graphics quality: Low / Medium |
| Crash at launch (fatalError in `GameController.init`) | the `Data` folder reference was not copied into the app bundle (check Copy Bundle Resources) |
| Bitrise `test` workflow fails | it is optional; `build_ipa` does not run the tests |

Upload to GitHub with `python tools/upload_to_github.py` (see the header of that file).
