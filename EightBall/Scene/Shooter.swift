import Foundation
import SceneKit
import simd

/// What a player at the table is doing.
enum ShooterState {
    case idle, walk, lean, aim, stroke, follow, unlean, celebrate, lose
}

/// Where he has to stand to take a shot.
struct Stance {
    var root: SIMD2<Double>
    var h: Double
    var variant: Int
    var slide: Double
}

/// Geometry helpers for walking round the table.
enum TableWalk {
    static let gap: Double = 0.05                 // the tip rests this far from the ball while he aims (it must travel this far to hit)
    static let marginStand: Double = 0.10         // his stance stays this far outside the table
    static let marginWalk: Double = 0.50          // walking round the table keeps this far away from it

    static func inside(_ x: Double, _ y: Double, margin m: Double) -> Bool {
        return abs(x) < TableGeometry.outerHalfX + m && abs(y) < TableGeometry.outerHalfY + m
    }

    /// Does the segment a-b cross the table rectangle grown by m?
    static func segmentHits(_ a: SIMD2<Double>, _ b: SIMD2<Double>, margin m: Double) -> Bool {
        let hx: Double = TableGeometry.outerHalfX + m
        let hy: Double = TableGeometry.outerHalfY + m
        var t0: Double = 0.0
        var t1: Double = 1.0
        let axes: [(lo: Double, hi: Double, p: Double, d: Double)] = [(-hx, hx, a.x, b.x - a.x), (-hy, hy, a.y, b.y - a.y)]
        for ax in axes {
            if abs(ax.d) < 1e-9 {
                if ax.p < ax.lo || ax.p > ax.hi { return false }
            } else {
                var u0: Double = (ax.lo - ax.p) / ax.d
                var u1: Double = (ax.hi - ax.p) / ax.d
                if u0 > u1 {
                    let tmp: Double = u0
                    u0 = u1
                    u1 = tmp
                }
                t0 = max(t0, u0)
                t1 = min(t1, u1)
                if t0 > t1 { return false }
            }
        }
        return true
    }

    /// Waypoints from a to b that go round the table when it is in the way (the shortest way through the rectangle's corners).
    static func path(from a: SIMD2<Double>, to b: SIMD2<Double>) -> [SIMD2<Double>] {
        if !segmentHits(a, b, margin: 0.05) {
            return [b]
        }
        let cx: Double = TableGeometry.outerHalfX + marginWalk
        let cy: Double = TableGeometry.outerHalfY + marginWalk
        let nodes: [SIMD2<Double>] = [a, b, SIMD2<Double>(-cx, -cy), SIMD2<Double>(cx, -cy), SIMD2<Double>(cx, cy), SIMD2<Double>(-cx, cy)]
        let n: Int = nodes.count
        var dist: [Double] = [Double](repeating: Double.infinity, count: n)
        var prev: [Int] = [Int](repeating: -1, count: n)
        var done: [Bool] = [Bool](repeating: false, count: n)
        dist[0] = 0
        while true {
            var i: Int = -1
            var best: Double = Double.infinity
            var k: Int = 0
            while k < n {
                if !done[k] && dist[k] < best {
                    best = dist[k]
                    i = k
                }
                k += 1
            }
            if i < 0 || i == 1 { break }
            done[i] = true
            var j: Int = 0
            while j < n {
                if !done[j] && j != i && !segmentHits(nodes[i], nodes[j], margin: 0.05) {
                    let dx: Double = nodes[j].x - nodes[i].x
                    let dy: Double = nodes[j].y - nodes[i].y
                    let d: Double = dist[i] + (dx * dx + dy * dy).squareRoot()
                    if d < dist[j] {
                        dist[j] = d
                        prev[j] = i
                    }
                }
                j += 1
            }
        }
        if dist[1] == Double.infinity {
            return [b]
        }
        var reversed: [SIMD2<Double>] = []
        var k: Int = 1
        while k != 0 && k >= 0 {
            reversed.append(nodes[k])
            k = prev[k]
        }
        return Array(reversed.reversed())
    }

    /// The smooth-step curve inverted: the x in 0...1 with x*x*(3-2x) = y.
    static func invSmooth(_ y: Double) -> Double {
        var lo: Double = 0.0
        var hi: Double = 1.0
        var i: Int = 0
        while i < 24 {
            let mid: Double = (lo + hi) / 2.0
            if mid * mid * (3.0 - 2.0 * mid) < y {
                lo = mid
            } else {
                hi = mid
            }
            i += 1
        }
        return lo
    }
}

/// A player at the table (you or the AI): walks round the table, leans over it, draws the cue back and strikes, and can celebrate or lose.
/// (A port of pg_shooter.py.) The whole body comes from clips baked in Blender and the cue sits in his hands on every frame: the clips carry
/// the cue's tip and direction. There are two Lean / Stroke variants: the second stretches further over the table.
@MainActor
final class Shooter {
    static let followTime: Double = 0.35          // he holds the follow through this long after the hit
    static let slideMax: Double = 0.45            // the cue may slide forward through his hands by this much when the ball is out of reach
    static let walkRate: Double = 24.0            // frames per second of the walk cycle at the baked walking speed
    static let turnRate: Double = 300.0           // degrees per second

    let name: String
    let person: Person
    let cue: SCNNode
    let home: SIMD2<Double>
    let homeHeading: Double
    private let assets: ManAssets

    private(set) var state: ShooterState = .idle
    private var path: [SIMD2<Double>] = []
    private var planTarget: SIMD2<Double>
    private var afterWalkLean: Bool = false
    private var finalHeading: Double?
    private(set) var stance: Stance = Stance(root: SIMD2<Double>(0, 0), h: 0, variant: 0, slide: 0)
    private var variant: Int = 0
    private var slide: Double = 0
    private var pullFrame: Double = 0
    private var contactCallback: (() -> Void)?
    private var contactFrame: Double = 0
    private var contacted: Bool = false
    private var dirtyTime: Double = 0
    private var timer: Double = 0

    /// Called when a foot touches the floor: x, y.
    var onFootstep: ((Double, Double) -> Void)?
    /// Called when the cue starts sliding forward through the bridge hand: the tip position.
    var onCueSlide: ((SIMD3<Double>) -> Void)?

    init(name: String, assets: ManAssets, variant: ManVariant, home: SIMD2<Double>, homeHeading: Double, cueDesign: String?, scene: PoolScene) {
        self.name = name
        self.assets = assets
        self.home = home
        self.homeHeading = homeHeading
        self.planTarget = home
        self.person = Person(assets: assets, variant: variant, name: name, parent: scene.gameRoot)
        self.cue = scene.makeCue(design: cueDesign)
        person.place(x: home.x, y: home.y, h: homeHeading)
        person.onStep = { [weak self] in
            guard let s = self else { return }
            s.onFootstep?(s.person.x, s.person.y)
        }
        resetPose()
    }

    // MARK: - helpers

    private func clipNames() -> (lean: String, stroke: String) {
        return variant != 0 ? ("Lean1", "Stroke1") : ("Lean", "Stroke")
    }

    private func restAnchor(variant v: Int) -> (tip: SIMD2<Double>, angleDeg: Double) {
        let clip: ManAssets.Clip = assets.clip(v != 0 ? "Stroke1" : "Stroke")
        let frame: Int = clip.start + Int(assets.strokeRest.rounded())
        let a = assets.anchor(frame: frame)
        return (SIMD2<Double>(a.tip.x, a.tip.y), SceneMath.degrees(atan2(a.dir.y, a.dir.x)))
    }

    private func rotate(_ h: Double, _ v: SIMD2<Double>) -> SIMD2<Double> {
        let c: Double = cos(SceneMath.radians(h))
        let s: Double = sin(SceneMath.radians(h))
        return SIMD2<Double>(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// Where he has to stand (root, heading, variant, how far the cue slides through his hands) to shoot from `ball` along `angle` (radians).
    func stanceFor(ball: SIMD2<Double>, angle: Double) -> Stance {
        let dx: Double = cos(angle)
        let dy: Double = sin(angle)
        let tipWorld: SIMD2<Double> = SIMD2<Double>(ball.x - dx * (TableGeometry.ballRadius + TableWalk.gap), ball.y - dy * (TableGeometry.ballRadius + TableWalk.gap))
        var best: Stance?
        for v in 0..<2 {
            let anchor = restAnchor(variant: v)
            let h: Double = SceneMath.degrees(angle) - anchor.angleDeg
            let o: SIMD2<Double> = rotate(h, anchor.tip)
            var root: SIMD2<Double> = SIMD2<Double>(tipWorld.x - o.x, tipWorld.y - o.y)
            var slideAmount: Double = 0.0
            if TableWalk.inside(root.x, root.y, margin: TableWalk.marginStand) {
                // the table is in the way: stand at its edge and slide the cue through the hands
                var t: Double = 0.0
                while t < 2.0 && TableWalk.inside(root.x - dx * t, root.y - dy * t, margin: TableWalk.marginStand) {
                    t += 0.01
                }
                slideAmount = t
                root = SIMD2<Double>(root.x - dx * t, root.y - dy * t)
            }
            let cand = Stance(root: root, h: h, variant: v, slide: slideAmount)
            if slideAmount == 0.0 {
                return cand
            }
            if let b = best {
                if cand.slide < b.slide { best = cand }
            } else {
                best = cand
            }
        }
        var result: Stance = best ?? Stance(root: tipWorld, h: 0, variant: 0, slide: 0)
        result.slide = min(result.slide, Shooter.slideMax)
        return result
    }

    func resetPose() {
        person.setClip("Idle", loop: true)
        state = .idle
    }

    // MARK: - commands from the game

    /// Walk to `target` (round the table if needed); `lean` starts leaning over the table on arrival.
    func walkTo(_ target: SIMD2<Double>, heading: Double?, lean: Bool) {
        path = TableWalk.path(from: SIMD2<Double>(person.x, person.y), to: target)
        planTarget = target
        finalHeading = heading
        afterWalkLean = lean
        state = .walk
        person.setClip("Walk", loop: true, blend: 0.2)
    }

    func goHome() {
        walkTo(home, heading: homeHeading, lean: false)
    }

    /// Walk to the place for this shot and lean over the table.
    func beginTurn(ball: SIMD2<Double>, angle: Double) {
        stance = stanceFor(ball: ball, angle: angle)
        variant = stance.variant
        slide = stance.slide
        contacted = false
        dirtyTime = 0
        if state == .aim || state == .lean {
            state = .unlean
            person.setClip(clipNames().lean, reverse: true, rate: 30.0, blend: 0.1)
            afterWalkLean = true
            return
        }
        walkTo(stance.root, heading: stance.h, lean: true)
    }

    /// Called every frame while he is the shooter: keeps his stance in line with the aim. Small changes pivot him round the ball; big ones
    /// make him stand up, walk to the new place and lean again (after the aim stopped moving for a moment).
    func aim(ball: SIMD2<Double>, angle: Double, moving: Bool, dt: Double) {
        let st: Stance = stanceFor(ball: ball, angle: angle)
        let cur: Stance = stance
        stance = st
        if state == .aim || state == .lean || state == .stroke {
            let dh: Double = abs(SceneMath.angleDiff(cur.h, st.h))
            let dx: Double = st.root.x - person.x
            let dy: Double = st.root.y - person.y
            let far: Bool = (dx * dx + dy * dy).squareRoot() > 0.32
            let big: Bool = dh > 12.0 || st.variant != variant || abs(st.slide - slide) > 0.12 || far
            if !big {
                let k: Double = 0.35
                let nx: Double = person.x + dx * k
                let ny: Double = person.y + dy * k
                let nh: Double = person.h + SceneMath.angleDiff(person.h, st.h) * k
                person.place(x: nx, y: ny, h: nh)
                dirtyTime = 0
            } else if state == .aim {
                dirtyTime = moving ? 0.0 : dirtyTime + dt
                if dirtyTime > 0.35 {
                    beginTurn(ball: ball, angle: angle)
                }
            }
        } else if (state == .walk || state == .unlean) && afterWalkLean {
            variant = st.variant
            slide = st.slide
            finalHeading = st.h
            let ex: Double = st.root.x - planTarget.x
            let ey: Double = st.root.y - planTarget.y
            if (ex * ex + ey * ey).squareRoot() > 0.05 {
                path = TableWalk.path(from: SIMD2<Double>(person.x, person.y), to: st.root)
                planTarget = st.root
            }
        }
    }

    /// True while he is leaning over the table in place: the player may draw the cue back.
    var ready: Bool {
        return state == .aim && dirtyTime == 0.0
    }

    /// Draw the cue back for a power 0...1 (scrubs the stroke clip).
    func charge(power: Double) {
        if state != .aim { return }
        let last: Int = assets.clip("Stroke").frames - 1
        pullFrame = assets.strokeRest + (Double(last) - assets.strokeRest) * TableWalk.invSmooth(power)
        person.scrub(clipNames().stroke, t: pullFrame)
    }

    func scrubRest() {
        person.scrub(clipNames().stroke, t: assets.strokeRest)
    }

    /// The forward stroke: the tip reaches the ball after the time the hand needs; `onContact` is called at that moment.
    func strike(power: Double, cueSpeed: Double, onContact: @escaping () -> Void) {
        let pullMeters: Double = assets.maxPull * power
        let cf: Double = assets.strokeRest - (TableWalk.gap / assets.follow) * assets.strokeRest
        let travel: Double = max(pullFrame - cf, 1.0)
        let t: Double = (pullMeters + TableWalk.gap) / max(cueSpeed * 0.8, 0.6)
        contactCallback = onContact
        contactFrame = cf
        contacted = false
        state = .stroke
        person.setClip(clipNames().stroke, reverse: true, rate: travel / max(t, 0.04), start: max(pullFrame, 0.5))
        onCueSlide?(person.cueWorld().tip)
    }

    func standUp() {
        if state == .aim || state == .stroke || state == .follow || state == .lean {
            state = .unlean
            afterWalkLean = false
            let frames: Int = assets.clip("Lean").frames
            person.setClip(clipNames().lean, reverse: true, rate: 30.0, blend: 0.12, start: Double(frames - 1))
        }
    }

    func celebrate() {
        state = .celebrate
        person.setClip("Cheer", loop: true, blend: 0.25)
    }

    func lose() {
        state = .lose
        person.setClip("Lose", loop: true, blend: 0.4)
    }

    // MARK: - per frame

    func update(dt: Double) {
        switch state {
        case .walk:
            walkStep(dt)
        case .lean:
            if person.done {
                state = .aim
                person.scrub(clipNames().stroke, t: assets.strokeRest)
                dirtyTime = 0
            }
        case .unlean:
            if person.done {
                if afterWalkLean {
                    walkTo(stance.root, heading: stance.h, lean: true)
                } else {
                    goHome()
                }
            }
        case .stroke:
            if !contacted && person.t <= contactFrame {
                contacted = true
                contactCallback?()
                contactCallback = nil
            }
            if person.done {
                state = .follow
                timer = 0
            }
        case .follow:
            timer += dt
            if timer > Shooter.followTime {
                standUp()
            }
        default:
            break
        }
        person.update(dt: dt)
        placeCue()
    }

    private func walkStep(_ dt: Double) {
        if let target = path.first {
            let dx: Double = target.x - person.x
            let dy: Double = target.y - person.y
            let dist: Double = (dx * dx + dy * dy).squareRoot()
            let want: Double = dist > 1e-6 ? SceneMath.degrees(atan2(dy, dx)) + 90.0 : person.h
            person.turnToward(want, maxStep: Shooter.turnRate * dt)
            let speed: Double = (path.count > 1 || dist > 0.8) ? 1.7 : max(0.5, 1.7 * dist / 0.8)
            if abs(SceneMath.angleDiff(person.h, want)) < 35.0 {
                let step: Double = min(speed * dt, dist)
                let inv: Double = 1.0 / max(dist, 1e-6)
                person.place(x: person.x + dx * inv * step, y: person.y + dy * inv * step)
                person.rate = Shooter.walkRate * (speed / assets.walkSpeed)
            } else {
                person.rate = Shooter.walkRate * 0.5
            }
            if dist < 0.04 {
                path.removeFirst()
            }
            return
        }
        let heading: Double = finalHeading ?? person.h
        if abs(SceneMath.angleDiff(person.h, heading)) > 3.0 {
            person.turnToward(heading, maxStep: Shooter.turnRate * dt)
            person.rate = Shooter.walkRate * 0.5
            return
        }
        if afterWalkLean {
            afterWalkLean = false
            state = .lean
            person.place(x: stance.root.x, y: stance.root.y, h: stance.h)
            person.setClip(clipNames().lean, blend: 0.15)
        } else {
            state = .idle
            person.setClip("Idle", loop: true, blend: 0.25)
        }
    }

    /// The cue is never seen sweeping back over the table: it vanishes while he straightens up and is back in his hand when he stands.
    private func cueVisible() -> Bool {
        if state == .follow {
            return timer < 0.2
        }
        if state == .unlean {
            return person.progress() < 0.3
        }
        return true
    }

    private func placeCue() {
        cue.isHidden = !cueVisible()
        let c = person.cueWorld()
        var s: Double = 0.0
        switch state {
        case .lean:
            s = slide * min(1.0, person.progress())
        case .unlean:
            s = slide * min(1.0, 1.0 - person.progress())
        case .aim, .stroke, .follow:
            s = slide
        default:
            s = 0.0
        }
        let p: SIMD3<Double> = c.tip + c.dir * s
        cue.simdPosition = SIMD3<Float>(Float(p.x), Float(p.y), Float(p.z))
        cue.simdOrientation = SceneMath.forwardYRotation(dir: c.dir)
    }
}
