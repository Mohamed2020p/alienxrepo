import Foundation
import SceneKit
import UIKit
import QuartzCore
import simd

/// Where the game flow is (a port of the `phase` of pool_game.py).
enum GamePhase {
    case menu       // the lounge with the main menu on top
    case place      // ball in hand: the human puts the cue ball down
    case aim        // the human aims and shoots
    case shoot      // the stroke animation, until the tip reaches the ball
    case roll       // the balls run
    case ai         // the AI plans, walks, aims and shoots
    case wait       // a short pause between two turns
    case over       // the game ended
}

enum AIStage {
    case think, move, hold, charge, fire
}

/// The game: turn flow, touch input, the physics loop, the AI, the sounds and the HUD state. It owns the 3D scene (`PoolScene`), the two players
/// (`Shooter`), the camera and the aim guide, and drives them from a display link. (A port of pool_game.py.)
@MainActor
final class GameController: NSObject, GameCommands {
    static let physicsStep: Double = 1.0 / 120.0
    static let headX: Double = PoolConst.HL / -2.0

    let model: GameModel = GameModel()
    let settings: GameSettings

    private let pool: PoolScene
    private let assets: ManAssets
    private let physics: Physics = Physics()
    private let rules: EightBallRules = EightBallRules()
    private var ai: AIPlanner?
    private var shooters: [Shooter] = []
    private let camera: CameraRig = CameraRig()
    private let guide: AimGuide
    private let audio: AudioManager
    private let haptics: Haptics = Haptics()

    private weak var scnView: SCNView?
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var fpsAccumulator: Double = 0
    private var fpsFrames: Int = 0

    private var phase: GamePhase = .menu
    private var paused: Bool = false
    private var aimAngle: Double = 0
    private var power: Double = 0
    private var charging: Bool = false
    private var spin: (x: Double, y: Double) = (0, 0)
    private var aimMoved: Bool = false
    private var guideOverride: Int?
    private var lastWrongBall: Int?
    private var accumulator: Double = 0
    private var shotTime: Double = 0
    private var placePosition: (x: Double, y: Double) = (GameController.headX, 0)
    private var placeOK: Bool = true
    private var firstTurn: Bool = true
    private var pending: (angle: Double, speed: Double, side: Double, top: Double) = (0, 0, 0, 0)
    private var later: [(remaining: Double, action: () -> Void)] = []
    private var messageTime: Double = 0
    private var shoutTime: Double = 0

    private var aiStage: AIStage = .think
    private var aiTimer: Double = 0
    private var aiShot: AIShot?
    private var aiTargetPower: Double = 0
    private var aiRate: Double = 1

    // MARK: - setup

    init(settings: GameSettings) {
        self.settings = settings
        guard let man = ManAssets() else {
            fatalError("Data/man.bin is missing - run tools/export_ios_data.py")
        }
        let poolScene: PoolScene = PoolScene(settings: settings)
        self.assets = man
        self.pool = poolScene
        self.guide = AimGuide(parent: poolScene.gameRoot)
        self.audio = AudioManager(volume: settings.volume)
        super.init()
        buildPlayers()
        for view in pool.balls {
            view.onRattle = { [weak self] (_: Double, _: Double, volume: Double) -> Void in
                self?.audio.play("rattle", volume: volume, variants: 3)
            }
            view.onDropFinished = { [weak self] (_: Int) -> Void in
                self?.updateTray()
            }
        }
        applySettings()
        newRack()
        refreshPlayers()
    }

    private func heading(from p: SIMD2<Double>, toward q: SIMD2<Double>) -> Double {
        return SceneMath.degrees(atan2(q.y - p.y, q.x - p.x)) + 90.0
    }

    private func buildPlayers() {
        let homeYou: SIMD2<Double> = SIMD2<Double>(-2.7, -2.1)
        let homeAI: SIMD2<Double> = SIMD2<Double>(2.7, 2.1)
        let centre: SIMD2<Double> = SIMD2<Double>(0, 0)
        let fallback: ManVariant? = assets.variants.values.first
        guard let vYou = assets.variants["pool_you"] ?? fallback, let vAI = assets.variants["pool_ai"] ?? fallback else {
            fatalError("Data/skins/variants.json has no outfits")
        }
        let you = Shooter(name: "you", assets: assets, variant: vYou, home: homeYou, homeHeading: heading(from: homeYou, toward: centre), cueDesign: "you", scene: pool)
        let opponent = Shooter(name: "ai", assets: assets, variant: vAI, home: homeAI, homeHeading: heading(from: homeAI, toward: centre), cueDesign: "ai", scene: pool)
        for s in [you, opponent] {
            s.onFootstep = { [weak self] (_: Double, _: Double) -> Void in
                self?.audio.footstep()
            }
            s.onCueSlide = { [weak self] (_: SIMD3<Double>) -> Void in
                self?.audio.play("cue_slide", volume: 0.3)
            }
        }
        shooters = [you, opponent]
    }

    /// Connects the 3D scene to the SCNView and starts the frame loop.
    func attach(to view: SCNView) {
        scnView = view
        view.scene = pool.scene
        view.pointOfView = pool.cameraNode
        view.backgroundColor = UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
        view.isPlaying = true
        view.rendersContinuously = true
        view.allowsCameraControl = false
        view.autoenablesDefaultLighting = false
        view.isJitteringEnabled = false
        applySettings()
        haptics.prepare()
        audio.setLoop("room", volume: 0.35)
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: RunLoop.main, forMode: RunLoop.Mode.common)
            displayLink = link
        }
        applyFrameRate()
    }

    private func applyFrameRate() {
        let fps: Float = Float(settings.profile.maxFPS)
        scnView?.preferredFramesPerSecond = Int(fps)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: fps, preferred: fps)
    }

    private func applySettings() {
        let profile: QualityProfile = settings.profile
        pool.applyQuality()
        assets.dynamicBudget = profile.dynamicPeople
        haptics.enabled = settings.haptics
        audio.setVolume(settings.volume)
        if let view = scnView {
            switch profile.msaaSamples {
            case 4: view.antialiasingMode = SCNAntialiasingMode.multisampling4X
            case 2: view.antialiasingMode = SCNAntialiasingMode.multisampling2X
            default: view.antialiasingMode = SCNAntialiasingMode.none
            }
        }
        applyFrameRate()
    }

    func settingsChanged() {
        applySettings()
        refreshPlayers()
    }

    // MARK: - GameCommands: flow

    func startGame() {
        paused = false
        firstTurn = true
        later.removeAll()
        newRack()
        rules.reset(firstPlayer: 0)
        for s in shooters {
            s.standUp()
            s.resetPose()
            s.person.place(x: s.home.x, y: s.home.y, h: s.homeHeading)
        }
        camera.mode = CameraMode.aim
        charging = false
        power = 0
        guideOverride = nil
        model.screen = ScreenPhase.playing
        model.shout = "BREAK!"
        shoutTime = 1.6
        model.gameOverTitle = ""
        audio.play("rack", volume: 0.9)
        beginTurn()
    }

    func restartGame() {
        startGame()
    }

    func pauseGame() {
        if model.screen == ScreenPhase.playing {
            paused = true
            charging = false
            model.screen = ScreenPhase.paused
        }
    }

    func resumeGame() {
        paused = false
        model.screen = ScreenPhase.playing
    }

    func quitToMenu() {
        paused = false
        phase = .menu
        charging = false
        later.removeAll()
        guide.hide()
        for s in shooters {
            s.standUp()
            s.resetPose()
            s.person.place(x: s.home.x, y: s.home.y, h: s.homeHeading)
        }
        newRack()
        model.screen = ScreenPhase.menu
        model.controlsVisible = false
        model.placingBall = false
        model.banner = ""
        model.message = ""
        model.shout = ""
    }

    // MARK: - GameCommands: shot controls

    func setPower(_ value: Double) {
        if phase != .aim || rules.current != 0 || paused { return }
        let shooter: Shooter = shooters[0]
        if !shooter.ready && !charging { return }
        charging = true
        power = max(0.0, min(1.0, value))
        shooter.charge(power: power)
        model.power = power
    }

    func releasePower() {
        if !charging { return }
        charging = false
        if power > 0.03 {
            doStrike(power: power)
        } else {
            power = 0
            shooters[0].scrubRest()
            model.power = 0
        }
    }

    func cancelPower() {
        if !charging { return }
        charging = false
        power = 0
        shooters[0].scrubRest()
        model.power = 0
    }

    func nudgeAim(_ radians: Double) {
        if phase != .aim || rules.current != 0 || charging { return }
        aimAngle += radians
        aimMoved = true
    }

    func setSpin(x: Double, y: Double) {
        var sx: Double = max(-1.0, min(1.0, x))
        var sy: Double = max(-1.0, min(1.0, y))
        let n: Double = (sx * sx + sy * sy).squareRoot()
        if n > 1.0 {
            sx /= n
            sy /= n
        }
        spin = (sx * 0.5, sy * 0.5)          // the tip stays on the ball: a circle of radius 0.5 R
        model.spinX = sx
        model.spinY = sy
    }

    func cycleCamera() {
        camera.cycle()
        model.cameraLabel = camera.mode.title
    }

    func cycleGuide() {
        let current: Int = guideOverride ?? settings.guideLevel
        guideOverride = (current + 1) % 4
        model.guideLabel = "Guide \(guideOverride ?? 0)"
    }

    func confirmPlacement() {
        if phase != .place { return }
        if !placeOK {
            setMessage("Not there: another ball is in the way", seconds: 1.5)
            return
        }
        physics.placeBall(0, x: placePosition.x, y: placePosition.y)
        pool.balls[0].forcedPosition = nil
        pool.balls[0].reset()
        audio.play("click_med", volume: 0.5, variants: 3)
        camera.mode = CameraMode.aim
        model.cameraLabel = camera.mode.title
        enterAim()
        refreshPlayers()
    }

    // MARK: - GameCommands: gestures

    func dragAim(dx: Double, dy: Double) {
        if phase != .aim || rules.current != 0 || charging || paused { return }
        aimAngle -= dx * 0.0035 * settings.sensitivity
        if dx != 0 { aimMoved = true }
    }

    func dragOrbit(dx: Double, dy: Double) {
        camera.orbit(dx: dx, dy: dy)
    }

    func pinch(scale: Double) {
        camera.pinch(scale: scale)
    }

    func dragPlace(to point: CGPoint, in view: SCNView) {
        if phase != .place { return }
        guard let hit = tablePoint(at: point, in: view) else { return }
        updatePlacement(x: hit.x, y: hit.y)
    }

    /// Where a touch in the SCNView hits the cloth (game coordinates), or nil.
    private func tablePoint(at point: CGPoint, in view: SCNView) -> SIMD2<Double>? {
        let near: SCNVector3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 0))
        let far: SCNVector3 = view.unprojectPoint(SCNVector3(Float(point.x), Float(point.y), 1))
        let n: SCNVector3 = pool.gameRoot.convertPosition(near, from: nil)
        let f: SCNVector3 = pool.gameRoot.convertPosition(far, from: nil)
        let dz: Float = f.z - n.z
        if abs(dz) < 1e-6 { return nil }
        let zPlane: Float = Float(TableGeometry.clothHeight + TableGeometry.ballRadius)
        let t: Float = (zPlane - n.z) / dz
        if t < 0 { return nil }
        return SIMD2<Double>(Double(n.x + (f.x - n.x) * t), Double(n.y + (f.y - n.y) * t))
    }

    private func updatePlacement(x: Double, y: Double) {
        let r: Double = PoolConst.R
        let x0: Double = -PoolConst.HL + r
        let x1: Double = (rules.kitchenOnly || rules.breakShot) ? GameController.headX : PoolConst.HL - r
        let cx: Double = min(max(x, x0), x1)
        let cy: Double = min(max(y, -PoolConst.HW + r), PoolConst.HW - r)
        placePosition = (cx, cy)
        placeOK = physics.isFree(x: cx, y: cy, radius: r, ignore: 0)
        pool.balls[0].forcedPosition = (cx, cy)
    }

    // MARK: - the game

    private func cueXY() -> SIMD2<Double> {
        let b: Ball = physics.balls[0]
        return SIMD2<Double>(b.x, b.y)
    }

    private func newRack() {
        physics.rack(seed: UInt64.random(in: 0..<(UInt64(1) << 30)))
        for v in pool.balls {
            v.reset()
            v.forcedPosition = nil
        }
        syncBalls(dt: 0)
        updateTray()
    }

    private func beginTurn() {
        let p: Int = rules.current
        updateTray()
        audio.play("turn", volume: 0.4)
        guide.hide()
        spin = (0, 0)
        model.spinX = 0
        model.spinY = 0
        power = 0
        model.power = 0
        charging = false
        shotTime = 0
        let needPlace: Bool = rules.ballInHand || firstTurn
        if p == 0 {
            if needPlace {
                camera.mode = CameraMode.top
                phase = .place
                model.placingBall = true
                model.controlsVisible = false
                placePosition = rules.ballInHand ? (physics.balls[0].x, physics.balls[0].y) : (GameController.headX, 0)
                updatePlacement(x: placePosition.x, y: placePosition.y)
                let behind: String = (rules.kitchenOnly || firstTurn) ? " (behind the line)" : ""
                setMessage("Ball in hand: drag the cue ball, then tap Place ball" + behind, seconds: 5.0)
            } else {
                camera.mode = CameraMode.aim
                enterAim()
            }
        } else {
            camera.mode = CameraMode.aim
            phase = .ai
            aiStage = .think
            model.controlsVisible = false
            model.placingBall = false
            let planner = AIPlanner(difficulty: settings.difficulty)
            planner.start(physics: physics, rules: rules, player: 1, seed: UInt64.random(in: 0..<(UInt64(1) << 30)))
            ai = planner
        }
        firstTurn = false
        model.cameraLabel = camera.mode.title
        refreshPlayers()
    }

    /// The human's shot: aim at the nearest ball he may hit, get in position.
    private func enterAim() {
        phase = .aim
        model.placingBall = false
        model.controlsVisible = true
        let c: SIMD2<Double> = cueXY()
        let targets: Set<Int> = rules.legalTargets(player: 0, physics: physics)
        var candidates: [Ball] = physics.activeBalls().filter { targets.contains($0.id) }
        if candidates.isEmpty {
            candidates = physics.activeBalls().filter { $0.id != 0 }
        }
        var best: Ball?
        var bestDistance: Double = Double.infinity
        for b in candidates {
            let d: Double = ((b.x - c.x) * (b.x - c.x) + (b.y - c.y) * (b.y - c.y)).squareRoot()
            if d < bestDistance {
                bestDistance = d
                best = b
            }
        }
        if let target = best {
            aimAngle = atan2(target.y - c.y, target.x - c.x)
        }
        shooters[0].beginTurn(ball: c, angle: aimAngle)
        audio.play("chalk", volume: 0.6)
    }

    private func cuePowerToSpeed(_ p: Double) -> Double {
        return 0.5 + 6.0 * p * p
    }

    private func speedToPower(_ v: Double) -> Double {
        return min(1.0, max(0.03, (max(v - 0.5, 0.0) / 6.0).squareRoot()))
    }

    private func doStrike(power p: Double) {
        let who: Int = rules.current
        phase = .shoot
        charging = false
        guide.hide()
        model.controlsVisible = false
        let speed: Double = cuePowerToSpeed(p)
        pending = (aimAngle, speed, spin.x, spin.y)
        shooters[who].strike(power: p, cueSpeed: speed, onContact: { [weak self] () -> Void in
            self?.onContact()
        })
    }

    /// The tip reaches the ball: the physics takes over.
    private func onContact() {
        rules.beginShot()
        physics.events.removeAll()
        physics.strike(angle: pending.angle, speed: pending.speed, side: pending.side, top: pending.top)
        let strength: Double = min(pending.speed / 6.5, 1.0)
        audio.tiered("cuehit", strength: strength)
        haptics.hit(strength: strength)
        camera.shake(min(pending.speed / 8.0, 0.8))
        phase = .roll
        accumulator = 0
        shotTime = 0
    }

    // MARK: - physics events

    private func handleEvents() {
        for ev in physics.events {
            rules.onEvent(ev)
            switch ev {
            case .ballBall(let a, let b, let speed):
                _ = a
                _ = b
                audio.tiered("click", strength: min(speed / 5.0, 1.0))
            case .cushion(_, let speed):
                if speed > 0.15 {
                    audio.tiered("cushion", strength: min(speed / 3.0, 1.0), scale: 0.9)
                }
            case .pocket(let id, let pocket, let speed):
                pool.balls[id].startDrop(from: physics.balls[id], pocket: pocket)
                audio.play("pocket", volume: min(1.0, 0.55 + speed * 0.1), variants: 3)
                camera.shake(0.25)
                haptics.pocket()
            case .cueHit:
                break
            }
        }
        physics.events.removeAll()
    }

    private func syncBalls(dt: Double) {
        var i: Int = 0
        while i < pool.balls.count {
            pool.balls[i].sync(physics.balls[i], dt: dt)
            i += 1
        }
    }

    private func finishShot() {
        let res: ShotResult = rules.endShot(physics: physics)
        for r in res.respot {
            physics.placeBall(r.id, x: r.x, y: r.y)
            pool.balls[r.id].reset()
        }
        if res.pocketed.contains(0) {
            setMessage("Scratch!", seconds: 2.0)
        }
        if res.foul {
            haptics.foul()
        }
        var text: String = rules.message
        if !res.gameOver {
            text += " " + (res.nextPlayer == 0 ? "You shoot." : "AI to shoot.")
        }
        setMessage(text, seconds: 6.0)
        updateTray()
        audio.setLoop("roll", volume: 0)
        for s in shooters {
            if s.state == .follow || s.state == .stroke || s.state == .aim {
                s.standUp()
            }
        }
        if res.gameOver, let winner = res.winner {
            gameOver(winner: winner)
        } else {
            later.append((remaining: 0.9, action: { [weak self] () -> Void in
                self?.beginTurn()
            }))
            phase = .wait
        }
    }

    private func gameOver(winner: Int) {
        phase = .over
        model.controlsVisible = false
        model.power = 0
        shooters[winner].celebrate()
        shooters[1 - winner].lose()
        audio.play(winner == 0 ? "applause" : "lose", volume: 0.8)
        audio.play(winner == 0 ? "win" : "lose", volume: 0.7)
        if winner == 0 { haptics.win() } else { haptics.lose() }
        model.shout = winner == 0 ? "YOU WIN!" : "THE AI WINS"
        shoutTime = 4.0
        later.append((remaining: 2.4, action: { [weak self] () -> Void in
            self?.showGameOver(winner: winner)
        }))
    }

    private func showGameOver(winner: Int) {
        model.youWon = winner == 0
        model.gameOverTitle = winner == 0 ? "YOU WIN!" : "THE AI WINS"
        model.gameOverSubtitle = winner == 0 ? "You won the game." : "The AI won this one."
        model.screen = ScreenPhase.over
    }

    // MARK: - HUD

    private func setMessage(_ text: String, seconds: Double) {
        model.message = text
        messageTime = seconds
    }

    private func groupName(_ p: Int) -> String {
        guard let g = rules.groups[p] else { return "open table" }
        return g == "solid" ? "solids 1-7" : "stripes 9-15"
    }

    private func refreshPlayers() {
        var list: [PlayerHUD] = model.players
        let names: [String] = ["YOU", "AI (\(settings.difficulty.rawValue))"]
        let avatars: [String] = ["tex/avatar_you.png", "tex/avatar_ai.png"]
        var p: Int = 0
        while p < 2 {
            var hud: PlayerHUD = p < list.count ? list[p] : PlayerHUD(name: names[p], avatar: avatars[p], groupText: "", targets: [], active: false)
            hud.name = names[p]
            hud.avatar = avatars[p]
            hud.groupText = groupName(p)
            hud.active = rules.current == p && phase != .over && model.screen != ScreenPhase.menu
            if p < list.count {
                list[p] = hud
            } else {
                list.append(hud)
            }
            p += 1
        }
        model.players = list
    }

    /// The one place that refreshes the target icons: each player's group (pocketed ones dimmed), then the 8 as the last target.
    private func updateTray() {
        var list: [PlayerHUD] = model.players
        var p: Int = 0
        while p < 2 && p < list.count {
            var targets: [TargetBall] = []
            if let g = rules.groups[p] {
                let ids: [Int] = g == "solid" ? Array(1...7) : Array(9...15)
                var anyActive: Bool = false
                for i in ids where physics.balls[i].state == BallState.active {
                    anyActive = true
                }
                if anyActive {
                    for i in ids {
                        targets.append(TargetBall(id: i, pocketed: physics.balls[i].state == BallState.pocketed))
                    }
                } else {
                    targets.append(TargetBall(id: 8, pocketed: physics.balls[8].state == BallState.pocketed))
                }
            }
            list[p].targets = targets
            p += 1
        }
        model.players = list
        refreshPlayers()
    }

    // MARK: - the loop

    @objc private func tick(_ link: CADisplayLink) {
        let now: CFTimeInterval = link.timestamp
        var dt: Double = lastTimestamp == 0 ? 1.0 / 60.0 : now - lastTimestamp
        lastTimestamp = now
        dt = min(max(dt, 0.001), 0.05)
        runFrame(dt: dt)
    }

    private func runFrame(dt: Double) {
        assets.dynamicUsed = 0
        fpsAccumulator += dt
        fpsFrames += 1
        if fpsAccumulator >= 0.5 {
            model.fps = Int((Double(fpsFrames) / fpsAccumulator).rounded())
            fpsAccumulator = 0
            fpsFrames = 0
        }
        if messageTime > 0 {
            messageTime -= dt
            if messageTime <= 0 { model.message = "" }
        }
        if shoutTime > 0 {
            shoutTime -= dt
            if shoutTime <= 0 { model.shout = "" }
        }
        var view: CameraView = .menu
        if !paused {
            runLater(dt: dt)
            view = stepGame(dt: dt)
            for s in shooters {
                s.update(dt: dt)
            }
            syncBalls(dt: dt)
        } else {
            view = cameraViewForPhase()
        }
        updateCamera(dt: dt, view: view)
        updateGuide()
        updateHUD()
        audio.update(dt: dt)
    }

    private func runLater(dt: Double) {
        var keep: [(remaining: Double, action: () -> Void)] = []
        var due: [() -> Void] = []
        for item in later {
            let left: Double = item.remaining - dt
            if left <= 0 {
                due.append(item.action)
            } else {
                keep.append((remaining: left, action: item.action))
            }
        }
        later = keep
        for action in due {
            action()
        }
    }

    private func cameraViewForPhase() -> CameraView {
        switch phase {
        case .menu: return .menu
        case .place: return .place
        case .aim, .shoot: return rules.current == 0 ? .aim : .watch
        case .ai: return .watch
        case .roll: return .roll
        case .wait: return rules.current != 0 ? .roll : .aim
        case .over: return .over
        }
    }

    private func stepGame(dt: Double) -> CameraView {
        switch phase {
        case .menu:
            return .menu
        case .place:
            model.banner = "BALL IN HAND"
            return .place
        case .aim:
            updateAim(dt: dt)
            return rules.current == 0 ? .aim : .watch
        case .ai:
            updateAI(dt: dt)
            return .watch
        case .shoot:
            return rules.current == 0 ? .aim : .watch
        case .roll:
            shotTime += dt
            accumulator += dt
            var n: Int = 0
            while accumulator >= GameController.physicsStep && n < 10 {
                physics.step(GameController.physicsStep)
                accumulator -= GameController.physicsStep
                n += 1
            }
            if n == 10 { accumulator = 0 }
            handleEvents()
            var top: Double = 0
            for b in physics.balls where b.state == BallState.active {
                let s: Double = (b.vx * b.vx + b.vy * b.vy).squareRoot()
                if s > top { top = s }
            }
            audio.setLoop("roll", volume: min(top / 2.2, 1.0) * 0.5)
            var dropping: Bool = false
            for v in pool.balls where v.isDropping {
                dropping = true
            }
            if !physics.moving() && shotTime > 0.4 && !dropping {
                finishShot()
            }
            model.banner = ""
            return .roll
        case .wait:
            model.banner = ""
            return rules.current != 0 ? .roll : .aim
        case .over:
            return .over
        }
    }

    // MARK: - the human aiming

    private func updateAim(dt: Double) {
        let shooter: Shooter = shooters[0]
        let c: SIMD2<Double> = cueXY()
        shooter.aim(ball: c, angle: aimAngle, moving: aimMoved, dt: dt)
        aimMoved = false
        model.canShoot = shooter.ready || charging
        model.banner = (shooter.ready || charging) ? "YOUR SHOT" : "..."
    }

    // MARK: - the AI

    private func updateAI(dt: Double) {
        let shooter: Shooter = shooters[1]
        let c: SIMD2<Double> = cueXY()
        switch aiStage {
        case .think:
            model.banner = "AI is thinking..."
            guard let planner = ai, let shot = planner.step(budget: 0.004) else { return }
            aiShot = shot
            if let place = shot.place {
                physics.placeBall(0, x: place.x, y: place.y)
                pool.balls[0].reset()
                audio.play("click_med", volume: 0.5, variants: 3)
            }
            aimAngle = shot.angle
            shooter.beginTurn(ball: cueXY(), angle: aimAngle)
            audio.play("chalk", volume: 0.6)
            aiStage = .move
        case .move:
            model.banner = "AI shoots"
            shooter.aim(ball: c, angle: aimAngle, moving: false, dt: dt)
            if shooter.ready {
                aiStage = .hold
                aiTimer = settings.difficulty == Difficulty.easy ? Double.random(in: 0.2...0.5) : Double.random(in: 0.5...1.0)
            }
        case .hold:
            shooter.aim(ball: c, angle: aimAngle, moving: false, dt: dt)
            aiTimer -= dt
            if aiTimer <= 0 {
                aiStage = .charge
                power = 0
                aiTargetPower = speedToPower(aiShot?.speed ?? 3.0)
                aiRate = 1.0 / (0.35 + 0.9 * aiTargetPower)
            }
        case .charge:
            shooter.aim(ball: c, angle: aimAngle, moving: false, dt: dt)
            power = min(aiTargetPower, power + dt * aiRate)
            shooter.charge(power: power)
            if power >= aiTargetPower - 1e-4, let shot = aiShot {
                aiStage = .fire
                spin = (shot.side, shot.top)
                pending = (shot.angle, shot.speed, shot.side, shot.top)
                phase = .shoot
                shooter.strike(power: power, cueSpeed: shot.speed, onContact: { [weak self] () -> Void in
                    self?.onContact()
                })
            }
        case .fire:
            break
        }
    }

    // MARK: - camera and guide

    private func updateCamera(dt: Double, view: CameraView) {
        let c: SIMD2<Double> = cueXY()
        var focus: SIMD2<Double>?
        if view == .roll {
            var sx: Double = 0
            var sy: Double = 0
            var count: Int = 0
            for b in physics.balls where b.state == BallState.active {
                let s: Double = (b.vx * b.vx + b.vy * b.vy).squareRoot()
                if s > 0.05 {
                    sx += b.x
                    sy += b.y
                    count += 1
                }
            }
            if count > 0 {
                focus = SIMD2<Double>(sx / Double(count), sy / Double(count))
            }
        }
        let out = camera.update(dt: dt, view: view, ball: c, aim: aimAngle, focus: focus)
        pool.setCamera(position: out.position, look: out.lookAt, fov: out.fov)
        let top: Bool = view == .place || (camera.mode == CameraMode.top && (view == .aim || view == .watch))
        let nearLamp: Bool = out.position.z > 1.6 && (out.position.x * out.position.x + out.position.y * out.position.y).squareRoot() < 4.0
        pool.setLampVisible(!(top || nearLamp))
    }

    private func updateGuide() {
        let show: Bool = phase == .aim && rules.current == 0 && !paused && shooters[0].state == ShooterState.aim
        let level: Int = guideOverride ?? settings.guideLevel
        if show && level > 0 {
            let legal: Set<Int> = rules.legalTargets(player: 0, physics: physics)
            guide.update(balls: physics.balls, start: cueXY(), angle: aimAngle, level: level, legal: legal)
            let wrong: Int? = guide.wrongBall
            if wrong != nil && lastWrongBall == nil {
                setMessage("Not your ball", seconds: 1.5)
            }
            lastWrongBall = wrong
            model.wrongBall = wrong != nil
        } else {
            guide.hide()
            lastWrongBall = nil
            model.wrongBall = false
        }
    }

    private func updateHUD() {
        model.guideLabel = "Guide \(guideOverride ?? settings.guideLevel)"
        if phase == .roll || phase == .wait || phase == .over || phase == .menu {
            model.canShoot = false
        }
    }
}
