import Foundation
import simd

/// What the camera is showing (the game's view, chosen by the game flow).
enum CameraView {
    case menu, over, place, aim, watch, roll
}

/// What the player cycles through with the camera button.
enum CameraMode: Int {
    case aim = 0
    case top = 1
    case orbit = 2

    var title: String {
        switch self {
        case .aim: return "Behind the cue"
        case .top: return "Top view"
        case .orbit: return "Free orbit"
        }
    }
}

/// The camera: behind the cue over the shooter's shoulder, straight down over the table, a free orbit, a high follow view while the balls roll,
/// and slow cinematic orbits for the menu and the end of the game. It glides between them and never leaves the room. (A port of pg_camera.py.)
@MainActor
final class CameraRig {
    static let topFOV: Double = 78.0
    static let viewFOV: Double = 58.0

    var mode: CameraMode = .aim
    var zoom: Double = 3.7                  // distance behind the ball
    var pitch: Double = 38.0                // degrees above the table
    var dyaw: Double = 0.0                  // orbit offset the player drags
    var orbitYaw: Double = 0.0
    var orbitPitch: Double = 32.0
    var dragging: Bool = false
    private(set) var position: SIMD3<Double> = SIMD3<Double>(0, -3.6, TableGeometry.clothHeight + 2.0)
    private(set) var lookAt: SIMD3<Double> = SIMD3<Double>(0, 0, TableGeometry.clothHeight)
    private(set) var fov: Double = CameraRig.viewFOV
    private var shakeAmount: Double = 0.0
    private var spin: Double = 0.0

    func cycle() {
        let next: Int = (mode.rawValue + 1) % 3
        mode = CameraMode(rawValue: next) ?? CameraMode.aim
        dyaw = 0.0
    }

    /// Pinch: `scale` > 1 zooms in.
    func pinch(scale: Double) {
        if scale <= 0 { return }
        zoom = min(4.4, max(1.5, zoom / scale))
    }

    /// Two fingers dragged (points): swing round and tilt.
    func orbit(dx: Double, dy: Double) {
        dyaw -= dx * 0.25
        pitch = min(70.0, max(8.0, pitch + dy * 0.2))
        orbitYaw -= dx * 0.25
        orbitPitch = min(80.0, max(5.0, orbitPitch + dy * 0.2))
    }

    func shake(_ amount: Double) {
        shakeAmount = max(shakeAmount, amount)
    }

    private func clamp(_ p: SIMD3<Double>) -> SIMD3<Double> {
        let hx: Double = PoolScene.roomHalfX
        let hy: Double = PoolScene.roomHalfY
        let hz: Double = PoolScene.roomHeight
        return SIMD3<Double>(max(-hx + 0.35, min(hx - 0.35, p.x)), max(-hy + 0.35, min(hy - 0.35, p.y)), max(0.5, min(hz - 0.15, p.z)))
    }

    /// view: what the game is showing; ball: cue ball (x, y); aim: radians; focus: (x, y) of the action while the balls roll.
    /// Returns the camera position, the point it looks at and the horizontal field of view (degrees).
    func update(dt: Double, view: CameraView, ball: SIMD2<Double>, aim: Double, focus: SIMD2<Double>?) -> (position: SIMD3<Double>, lookAt: SIMD3<Double>, fov: Double) {
        let h: Double = TableGeometry.clothHeight
        var wantFOV: Double = CameraRig.viewFOV
        var rate: Double = 5.0
        var pos: SIMD3<Double>
        let look: SIMD3<Double>
        if view == .menu || view == .over {
            spin += dt * 9.0
            let a: Double = (spin + 210.0) * Double.pi / 180.0
            let c: SIMD3<Double> = SIMD3<Double>(0, 0, h + 0.3)
            pos = c + SIMD3<Double>(cos(a) * 3.3, sin(a) * 3.3, 1.5)
            look = c
            rate = 2.0
        } else if view == .place || ((view == .aim || view == .watch) && mode == .top) {
            pos = SIMD3<Double>(0.0, -0.02, 3.0)
            look = SIMD3<Double>(0, 0, h)
            wantFOV = CameraRig.topFOV
        } else if view == .roll {
            let f: SIMD2<Double> = focus ?? ball
            let yaw: Double = aim + dyaw * Double.pi / 180.0
            let d: SIMD3<Double> = SIMD3<Double>(cos(yaw), sin(yaw), 0)
            let p: Double = 50.0 * Double.pi / 180.0
            look = SIMD3<Double>(f.x * 0.7, f.y * 0.7, h)
            let back: SIMD3<Double> = d * (3.0 * cos(p))
            let lift: SIMD3<Double> = SIMD3<Double>(0, 0, 3.0 * sin(p))
            pos = look - back + lift
            rate = 2.4
        } else if mode == .orbit && (view == .aim || view == .watch) {
            let a: Double = orbitYaw * Double.pi / 180.0
            let p: Double = orbitPitch * Double.pi / 180.0
            look = SIMD3<Double>(0, 0, h)
            let offset: SIMD3<Double> = SIMD3<Double>(cos(a) * cos(p), sin(a) * cos(p), sin(p))
            pos = look + offset * 3.6
        } else {
            if !dragging {
                dyaw += (0.0 - dyaw) * min(1.0, 1.2 * dt)
            }
            let yaw: Double = aim + (dyaw + (view == .watch ? 42.0 : 0.0)) * Double.pi / 180.0
            let d: SIMD3<Double> = SIMD3<Double>(cos(yaw), sin(yaw), 0)
            let right: SIMD3<Double> = SIMD3<Double>(d.y, -d.x, 0)
            let p: Double = (view == .aim ? pitch : 34.0) * Double.pi / 180.0
            let dist: Double = view == .aim ? zoom : 3.6
            let base: SIMD3<Double> = SIMD3<Double>(ball.x, ball.y, h + 0.06)
            look = base + d * 0.55
            let shoulder: Double = view == .aim ? 0.35 : 0.0
            let back: SIMD3<Double> = d * (dist * cos(p))
            let lift: SIMD3<Double> = SIMD3<Double>(0, 0, dist * sin(p))
            let side: SIMD3<Double> = right * shoulder
            pos = base - back + lift + side
        }
        pos = clamp(pos)
        let k: Double = 1.0 - exp(-dt * rate)
        position = position + (pos - position) * k
        lookAt = lookAt + (look - lookAt) * k
        fov += (wantFOV - fov) * (1.0 - exp(-dt * 4.0))
        var out: SIMD3<Double> = position
        if shakeAmount > 0.005 {
            let a: Double = shakeAmount
            let jitter: SIMD3<Double> = SIMD3<Double>(Double.random(in: -a...a), Double.random(in: -a...a), Double.random(in: -a...a))
            out += jitter * 0.02
            shakeAmount *= max(0.0, 1.0 - 5.0 * dt)
        }
        return (out, lookAt, fov)
    }
}
