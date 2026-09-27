import Foundation

// Headless 2D billiard physics (metres, SI): a faithful port of pg_physics.py.
//
// Table centre is the origin, X runs along the long side, Y across, Z is up. Balls are simulated on the cloth plane only but carry a
// full angular velocity so follow, draw, stop and side spin behave naturally. The engine is deterministic (no random numbers in
// `step`) and sub-steps adaptively so no ball moves more than 0.4 R per sub-step. Everything that leaves the engine is appended to
// `Physics.events`, which the caller drains.
//
// Pockets: a ball whose centre gets within the capture radius of a pocket centre drops in, at any speed. There is no bounce-out.

// MARK: - Constants

enum PoolConst {
    static let R: Double = 0.02858                      // ball radius
    static let D: Double = 2.0 * PoolConst.R            // centre distance at contact
    static let D2: Double = PoolConst.D * PoolConst.D
    static let mass: Double = 0.17
    static let grav: Double = 9.81
    static let HL: Double = 1.27                        // half length / half width of the playing surface
    static let HW: Double = 0.635
    static let headX: Double = -PoolConst.HL / 2.0      // head string
    static let footX: Double = PoolConst.HL / 2.0       // foot spot x

    // cloth
    static let muSlide: Double = 0.2
    static let muRoll: Double = 0.013
    static let spinA: Double = 8.0                      // vertical spin decay: constant + proportional part
    static let spinB: Double = 1.2
    static let snapV: Double = 0.002                    // rolling balls slower than this stop dead

    // ball-ball / cushion
    static let eBall: Double = 0.95
    static let eKnuckle: Double = 0.7
    static let muCushion: Double = 0.18
    static let cushionH: Double = 0.4 * PoolConst.R     // contact height above the ball centre

    // geometry
    static let longX0: Double = 0.085                   // long cushion spans |x| in [longX0, longX1]
    static let longX1: Double = PoolConst.HL - 0.100
    static let shortY1: Double = PoolConst.HW - 0.100   // short cushions span |y| <= shortY1
    static let knuckleR: Double = 0.002
    static let cornerPocket: (Double, Double) = (1.302, 0.667)
    static let sidePocketY: Double = 0.699
    static let capCorner: Double = 0.085                // capture radii: a ball whose centre gets this close to a pocket's centre drops in
    static let capSide: Double = 0.090

    /// The twelve cushion-end knuckles in the Python order (sx, sy in -1, 1; then long-x0, long-x1, short-end).
    static let knuckles: [(Double, Double)] = PoolConst.makeKnuckles()
    static let knuckleX: [Double] = PoolConst.knuckles.map { $0.0 }
    static let knuckleY: [Double] = PoolConst.knuckles.map { $0.1 }

    // derived constants used in the inner loop
    static let invR: Double = 1.0 / PoolConst.R
    static let cw: Double = 2.5 / PoolConst.R           // dw = cw * friction acceleration * dt
    static let muSG: Double = PoolConst.muSlide * PoolConst.grav
    static let muRG: Double = PoolConst.muRoll * PoolConst.grav
    static let invSlide: Double = 1.0 / (3.5 * PoolConst.muSG)
    static let kn: Double = PoolConst.makeKN()          // normal impulse factor
    static let kt: Double = PoolConst.makeKT()          // tangential impulse factor
    static let ir2: Double = 2.5 / (PoolConst.R * PoolConst.R)
    static let maxMove: Double = 0.4 * PoolConst.R      // largest distance a ball may travel per sub-step
    static let hmax: Double = 1.0 / 120.0
    static let mRatio: Double = PoolConst.mass / 0.54   // ball / cue mass
    static let rk: Double = PoolConst.R + PoolConst.knuckleR
    static let rk2: Double = PoolConst.rk * PoolConst.rk
    static let xl: Double = PoolConst.HL - PoolConst.R
    static let yl: Double = PoolConst.HW - PoolConst.R
    static let xb: Double = PoolConst.xl - PoolConst.knuckleR    // outside this box a ball may touch cushions or pockets
    static let yb: Double = PoolConst.yl - PoolConst.knuckleR

    private static func makeKnuckles() -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        let signs: [Double] = [-1.0, 1.0]
        let base: [(Double, Double)] = [
            (PoolConst.longX0, PoolConst.HW),
            (PoolConst.longX1, PoolConst.HW),
            (PoolConst.HL, PoolConst.shortY1)
        ]
        for sx in signs {
            for sy in signs {
                for k in base {
                    out.append((sx * k.0, sy * k.1))
                }
            }
        }
        return out
    }

    private static func makeKN() -> Double {
        let q: Double = PoolConst.cushionH / PoolConst.R
        return 1.0 / (1.0 + 2.5 * (q * q))
    }

    private static func makeKT() -> Double {
        let q: Double = PoolConst.cushionH / PoolConst.R
        return 1.0 / (3.5 + 2.5 * (q * q))
    }
}

// MARK: - Balls and events

enum BallState {
    case active
    case pocketed
}

final class Ball {
    let id: Int
    var x: Double = 0.0
    var y: Double = 0.0
    var vx: Double = 0.0
    var vy: Double = 0.0
    var wx: Double = 0.0
    var wy: Double = 0.0
    var wz: Double = 0.0
    var state: BallState = BallState.active
    var pocket: Int? = nil
    var dropSpeed: Double = 0.0
    var dropDirX: Double = 0.0
    var dropDirY: Double = 0.0

    init(id: Int) {
        self.id = id
    }
}

enum PhysicsEvent {
    case cueHit(id: Int, speed: Double)
    case ballBall(a: Int, b: Int, speed: Double)       // a < b
    case cushion(id: Int, speed: Double)
    case pocket(id: Int, pocket: Int, speed: Double)
}

/// One ball's complete state inside a `BallSnapshot`.
struct BallRecord {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var wx: Double
    var wy: Double
    var wz: Double
    var state: BallState
    var pocket: Int?
    var dropSpeed: Double
    var dropDirX: Double
    var dropDirY: Double
}

/// Cheap copy of every ball's state (16 records, index == ball id).
struct BallSnapshot {
    var balls: [BallRecord]
}

// MARK: - The engine

final class Physics {
    var balls: [Ball]                       // 16, index == id (0 = cue ball)
    var events: [PhysicsEvent]              // the caller drains it: `physics.events.removeAll()`

    private var act: [Ball]                 // the active balls, ascending id
    private var flags: [Bool]               // ball is moving (per sub-step scratch)
    private var mov: [Ball]                 // the moving balls of the current sub-step
    private var dirty: Bool

    init(empty: Bool = false) {
        var list: [Ball] = []
        list.reserveCapacity(16)
        for i in 0..<16 {
            list.append(Ball(id: i))
        }
        var ev: [PhysicsEvent] = []
        ev.reserveCapacity(64)
        var scratch: [Ball] = []
        scratch.reserveCapacity(16)
        var live: [Ball] = []
        live.reserveCapacity(16)
        self.balls = list
        self.events = ev
        self.act = live
        self.flags = Array(repeating: false, count: 16)
        self.mov = scratch
        self.dirty = false
        if !empty {
            self.rack(seed: 0)
        }
    }

    // MARK: setup

    /// Standard 8-ball rack: apex on the foot spot, 8 in the middle, mixed back corners.
    func rack(seed: UInt64?) {
        var rng = SplitMix64(seed: seed ?? SplitMix64.randomSeed())
        var solids: [Int] = Array(1...7)
        var stripes: [Int] = Array(9...15)
        solids.shuffle(using: &rng)
        stripes.shuffle(using: &rng)
        let cornerSolid: Int = solids.removeLast()
        let cornerStripe: Int = stripes.removeLast()
        var corners: [Int] = [cornerSolid, cornerStripe]
        corners.shuffle(using: &rng)
        var rest: [Int] = solids + stripes
        rest.shuffle(using: &rng)
        var order: [Int] = []
        for slot in 0..<15 {
            if slot == 4 {
                order.append(8)
            } else if slot == 10 {
                order.append(corners[0])
            } else if slot == 14 {
                order.append(corners[1])
            } else {
                order.append(rest.removeLast())
            }
        }
        let pitch: Double = PoolConst.D + 1e-4
        let rowDx: Double = pitch * sqrt(3.0) / 2.0
        var slotIndex: Int = 0
        for row in 0..<5 {
            for col in 0...row {
                let px: Double = PoolConst.footX + Double(row) * rowDx
                let py: Double = (Double(col) - Double(row) / 2.0) * pitch
                placeBall(order[slotIndex], x: px, y: py)
                slotIndex += 1
            }
        }
        placeBall(0, x: PoolConst.headX, y: 0.0)
    }

    /// Put any ball on the cloth at rest (also brings a pocketed ball back).
    func placeBall(_ i: Int, x: Double, y: Double) {
        let b: Ball = balls[i]
        b.x = x
        b.y = y
        b.vx = 0.0
        b.vy = 0.0
        b.wx = 0.0
        b.wy = 0.0
        b.wz = 0.0
        b.state = BallState.active
        b.pocket = nil
        b.dropSpeed = 0.0
        refreshActive()
    }

    func resetCue(x: Double, y: Double) {
        placeBall(0, x: x, y: y)
    }

    /// Rebuilds the list of active balls from the balls' `state` (call it after changing `state` by hand).
    func refreshActive() {
        act.removeAll(keepingCapacity: true)
        for b in balls {
            if b.state == BallState.active {
                act.append(b)
            }
        }
    }

    /// True if a ball of `radius` fits at (x, y): on the cloth and clear of all active balls.
    func isFree(x: Double, y: Double, radius: Double = PoolConst.R, ignore: Int? = nil) -> Bool {
        if abs(x) > PoolConst.HL - radius || abs(y) > PoolConst.HW - radius {
            return false
        }
        let rr: Double = radius + PoolConst.R
        var lim: Double = rr * rr
        for b in act {
            if let ig = ignore {
                if b.id == ig {
                    continue
                }
            }
            let dx: Double = b.x - x
            let dy: Double = b.y - y
            if dx * dx + dy * dy < lim {
                return false
            }
        }
        let rk: Double = radius + PoolConst.knuckleR
        lim = rk * rk
        let kxs: [Double] = PoolConst.knuckleX
        let kys: [Double] = PoolConst.knuckleY
        for i in 0..<kxs.count {
            let dx: Double = kxs[i] - x
            let dy: Double = kys[i] - y
            if dx * dx + dy * dy < lim {
                return false
            }
        }
        return true
    }

    func activeBalls() -> [Ball] {
        return act
    }

    func moving() -> Bool {
        for b in act {
            if b.vx != 0.0 || b.vy != 0.0 || b.wx != 0.0 || b.wy != 0.0 || b.wz != 0.0 {
                return true
            }
        }
        return false
    }

    func snapshot() -> BallSnapshot {
        var out: [BallRecord] = []
        out.reserveCapacity(balls.count)
        for b in balls {
            let rec = BallRecord(x: b.x, y: b.y, vx: b.vx, vy: b.vy, wx: b.wx, wy: b.wy, wz: b.wz,
                                 state: b.state, pocket: b.pocket, dropSpeed: b.dropSpeed,
                                 dropDirX: b.dropDirX, dropDirY: b.dropDirY)
            out.append(rec)
        }
        return BallSnapshot(balls: out)
    }

    func restore(_ s: BallSnapshot) {
        let n: Int = min(balls.count, s.balls.count)
        for i in 0..<n {
            let b: Ball = balls[i]
            let rec: BallRecord = s.balls[i]
            b.x = rec.x
            b.y = rec.y
            b.vx = rec.vx
            b.vy = rec.vy
            b.wx = rec.wx
            b.wy = rec.wy
            b.wz = rec.wz
            b.state = rec.state
            b.pocket = rec.pocket
            b.dropSpeed = rec.dropSpeed
            b.dropDirX = rec.dropDirX
            b.dropDirY = rec.dropDirY
        }
        refreshActive()
    }

    // MARK: cue

    /// Cue tip hits the cue ball: `speed` is the cue speed, side/top the tip offset in R.
    func strike(angle: Double, speed: Double, side: Double = 0.0, top: Double = 0.0) {
        let sp: Double = min(12.0, max(0.3, speed))
        let sd: Double = min(0.5, max(-0.5, side))
        let tp: Double = min(0.5, max(-0.5, top))
        let denom: Double = 1.0 + PoolConst.mRatio + 2.5 * (sd * sd + tp * tp)
        let v: Double = 2.0 * sp / denom
        let ca: Double = cos(angle)
        let sa: Double = sin(angle)
        let c: Ball = balls[0]
        c.vx = v * ca
        c.vy = v * sa
        let roll: Double = PoolConst.cw * v * tp        // spin about the axis left of the shot line
        c.wx = -sa * roll
        c.wy = ca * roll
        c.wz = PoolConst.cw * v * sd
        events.append(PhysicsEvent.cueHit(id: 0, speed: v))
    }

    // MARK: time step

    /// Advance by dt seconds with adaptive sub-stepping.
    func step(_ dt: Double) {
        var vm2: Double = 0.0
        var live: Bool = false
        for b in act {
            let s: Double = b.vx * b.vx + b.vy * b.vy
            if s > vm2 {
                vm2 = s
            }
            if s != 0.0 || b.wx != 0.0 || b.wy != 0.0 || b.wz != 0.0 {
                live = true
            }
        }
        if !live {
            return
        }
        if !vm2.isFinite {
            return
        }
        var n: Int = Int(((dt / PoolConst.hmax) - 1e-9).rounded(.up))
        let m: Int = Int(((dt * sqrt(vm2) / PoolConst.maxMove) - 1e-9).rounded(.up))
        if m > n {
            n = m
        }
        if n < 1 {
            return
        }
        let h: Double = dt / Double(n)
        for _ in 0..<n {
            sub(h)
        }
    }

    private func sub(_ h: Double) {
        mov.removeAll(keepingCapacity: true)
        let r: Double = PoolConst.R
        let invR: Double = PoolConst.invR
        let cw: Double = PoolConst.cw
        let muSG: Double = PoolConst.muSG
        let muRG: Double = PoolConst.muRG
        let invSlide: Double = PoolConst.invSlide
        let snapV: Double = PoolConst.snapV
        let spinA: Double = PoolConst.spinA
        let spinB: Double = PoolConst.spinB
        for b in act {
            var vx: Double = b.vx
            var vy: Double = b.vy
            var wx: Double = b.wx
            var wy: Double = b.wy
            var wz: Double = b.wz
            if vx == 0.0 && vy == 0.0 && wx == 0.0 && wy == 0.0 && wz == 0.0 {
                flags[b.id] = false
                continue
            }
            flags[b.id] = true
            mov.append(b)
            var x: Double = b.x
            var y: Double = b.y
            let ux: Double = vx - r * wy
            let uy: Double = vy + r * wx
            let us2: Double = ux * ux + uy * uy
            var hr: Double = h
            if us2 > 1e-8 {                                 // sliding on the cloth
                let us: Double = sqrt(us2)
                let ts: Double = us * invSlide
                let hs: Double = h < ts ? h : ts
                let k: Double = muSG / us
                let ax: Double = -k * ux
                let ay: Double = -k * uy
                let hh: Double = 0.5 * hs * hs
                x += vx * hs + ax * hh
                y += vy * hs + ay * hh
                vx += ax * hs
                vy += ay * hs
                wx += cw * ay * hs
                wy -= cw * ax * hs
                hr = h - hs
                if hr > 0.0 {                               // slip ended inside this step
                    wx = -vy * invR
                    wy = vx * invR
                }
            }
            if hr > 0.0 {                                   // rolling with resistance
                let sp2: Double = vx * vx + vy * vy
                if sp2 > 0.0 {
                    let sp: Double = sqrt(sp2)
                    let dec: Double = muRG * hr
                    if sp > dec {
                        let d: Double = hr - 0.5 * muRG * hr * hr / sp
                        x += vx * d
                        y += vy * d
                        let f: Double = (sp - dec) / sp
                        vx *= f
                        vy *= f
                        if sp - dec < snapV {
                            vx = 0.0
                            vy = 0.0
                        }
                    } else {
                        let d: Double = 0.5 * sp / muRG
                        x += vx * d
                        y += vy * d
                        vx = 0.0
                        vy = 0.0
                    }
                }
                wx = -vy * invR
                wy = vx * invR
            }
            if wz != 0.0 {
                let aw: Double = abs(wz)
                let dw: Double = (spinA + spinB * aw) * h
                if aw <= dw || aw < 0.05 {
                    wz = 0.0
                } else if wz > 0.0 {
                    wz -= dw
                } else {
                    wz += dw
                }
            }
            b.x = x
            b.y = y
            b.vx = vx
            b.vy = vy
            b.wx = wx
            b.wy = wy
            b.wz = wz
        }
        let xb: Double = PoolConst.xb
        let yb: Double = PoolConst.yb
        var iter: Int = 0
        while iter < 4 {
            iter += 1
            var hit: Bool = pairs(h)
            for b in mov {
                let x: Double = b.x
                let y: Double = b.y
                if x > xb || x < -xb || y > yb || y < -yb {
                    if b.state == BallState.active {
                        if edge(b, h) {
                            hit = true
                        }
                    }
                }
            }
            if dirty {
                dirty = false
                act = act.filter { $0.state == BallState.active }
                mov = mov.filter { $0.state == BallState.active }
            }
            if !hit {
                break
            }
        }
    }

    // MARK: ball-ball

    /// Resolve overlaps between moving balls and any other ball; true if something collided.
    private func pairs(_ h: Double) -> Bool {
        let actList: [Ball] = act
        let dd: Double = PoolConst.D
        let dd2: Double = PoolConst.D2
        let eBall: Double = PoolConst.eBall
        var hit: Bool = false
        var i: Int = 0
        while i < mov.count {                               // balls set moving by an impulse join the list
            let a: Ball = mov[i]
            i += 1
            let aid: Int = a.id
            var ax: Double = a.x
            var ay: Double = a.y
            for b in actList {
                var dx: Double = b.x - ax
                if dx > dd || dx < -dd {
                    continue
                }
                var dy: Double = b.y - ay
                if dy > dd || dy < -dd {
                    continue
                }
                let bid: Int = b.id
                if bid == aid || (flags[bid] && bid < aid) {
                    continue                                // moving pairs are handled from the lower id
                }
                var d2: Double = dx * dx + dy * dy
                if d2 >= dd2 {
                    continue
                }
                hit = true
                let vrx: Double = a.vx - b.vx
                let vry: Double = a.vy - b.vy
                let vv: Double = vrx * vrx + vry * vry
                let dv: Double = -(dx * vrx + dy * vry)     // < 0 while the balls approach
                if vv > 1e-12 && dv < 0.0 {
                    var tau: Double = (dv + sqrt(dv * dv + vv * (dd2 - d2))) / vv   // time since first touch
                    if tau > h {
                        tau = h
                    }
                    let nx: Double = (dx + vrx * tau) / dd
                    let ny: Double = (dy + vry * tau) / dd
                    let vn: Double = vrx * nx + vry * ny
                    if vn > 0.0 {
                        let jImp: Double = 0.5 * (1.0 + eBall) * vn
                        a.vx -= jImp * nx
                        a.vy -= jImp * ny
                        b.vx += jImp * nx
                        b.vy += jImp * ny
                        a.x -= jImp * nx * tau
                        a.y -= jImp * ny * tau
                        b.x += jImp * nx * tau
                        b.y += jImp * ny * tau
                        if !flags[bid] {
                            flags[bid] = true
                            mov.append(b)
                        }
                        if vn > 0.01 {
                            if aid < bid {
                                events.append(PhysicsEvent.ballBall(a: aid, b: bid, speed: vn))
                            } else {
                                events.append(PhysicsEvent.ballBall(a: bid, b: aid, speed: vn))
                            }
                        }
                    }
                }
                dx = b.x - a.x
                dy = b.y - a.y
                d2 = dx * dx + dy * dy
                if d2 < dd2 {                               // still overlapping: push apart
                    var d: Double = 0.0
                    var nx: Double = 1.0
                    var ny: Double = 0.0
                    if d2 > 1e-18 {
                        d = sqrt(d2)
                        nx = dx / d
                        ny = dy / d
                    }
                    let s: Double = (dd - d) * 0.5 + 1e-9
                    a.x -= nx * s
                    a.y -= ny * s
                    b.x += nx * s
                    b.y += ny * s
                }
                ax = a.x
                ay = a.y
            }
        }
        return hit
    }

    // MARK: cushions, knuckles, pockets

    /// Handle a ball close to the rails; true if it collided or was pocketed.
    private func edge(_ b: Ball, _ h: Double) -> Bool {
        let hl: Double = PoolConst.HL
        let hw: Double = PoolConst.HW
        let x: Double = b.x
        let y: Double = b.y
        let ax: Double = x < 0.0 ? -x : x
        let ay: Double = y < 0.0 ? -y : y
        let cpx: Double = PoolConst.cornerPocket.0
        let cpy: Double = PoolConst.cornerPocket.1
        let sideY: Double = PoolConst.sidePocketY
        if ax > hl || ay > hw {                             // passed through a mouth
            let sy: Double = ay - sideY
            let dSide: Double = x * x + sy * sy
            let cx: Double = ax - cpx
            let cy: Double = ay - cpy
            let dCorner: Double = cx * cx + cy * cy
            if ax > hl || dCorner < dSide {
                dropBall(b, cornerIndex(x, y))
            } else {
                dropBall(b, y > 0.0 ? 5 : 4)
            }
            return true
        }
        if ax > 1.2 && ay > 0.58 {
            let dx: Double = (x > 0.0 ? cpx : -cpx) - x
            let dy: Double = (y > 0.0 ? cpy : -cpy) - y
            let cap: Double = PoolConst.capCorner
            if dx * dx + dy * dy < cap * cap {
                dropBall(b, cornerIndex(x, y))                // captured: it drops in, always
                return true
            }
        } else if ay > 0.6 && ax < 0.1 {
            let dx: Double = -x
            let dy: Double = (y > 0.0 ? sideY : -sideY) - y
            let cap: Double = PoolConst.capSide
            if dx * dx + dy * dy < cap * cap {
                dropBall(b, y > 0.0 ? 5 : 4)
                return true
            }
        }
        var hit: Bool = false
        let yl: Double = PoolConst.yl
        let xl: Double = PoolConst.xl
        let longX0: Double = PoolConst.longX0
        let longX1: Double = PoolConst.longX1
        let shortY1: Double = PoolConst.shortY1
        if y > yl {
            if longX0 <= ax && ax <= longX1 {
                hit = cushionHit(b, 0.0, -1.0, y - yl, h)
            }
        } else if y < -yl {
            if longX0 <= ax && ax <= longX1 {
                hit = cushionHit(b, 0.0, 1.0, -yl - y, h)
            }
        }
        if x > xl {
            if ay <= shortY1 {
                let c: Bool = cushionHit(b, -1.0, 0.0, x - xl, h)
                hit = c || hit
            }
        } else if x < -xl {
            if ay <= shortY1 {
                let c: Bool = cushionHit(b, 1.0, 0.0, -xl - x, h)
                hit = c || hit
            }
        }
        let rk: Double = PoolConst.rk
        let rk2: Double = PoolConst.rk2
        let eKnuckle: Double = PoolConst.eKnuckle
        let kxs: [Double] = PoolConst.knuckleX
        let kys: [Double] = PoolConst.knuckleY
        for i in 0..<kxs.count {
            let kx: Double = kxs[i]
            let ky: Double = kys[i]
            let dx: Double = b.x - kx
            if dx > rk || dx < -rk {
                continue
            }
            let dy: Double = b.y - ky
            let d2: Double = dx * dx + dy * dy
            if d2 >= rk2 {
                continue
            }
            let d: Double = d2 > 1e-18 ? sqrt(d2) : 1e-9
            let nx: Double = dx / d
            let ny: Double = dy / d
            let vn: Double = b.vx * nx + b.vy * ny
            if vn < 0.0 {
                let f: Double = (1.0 + eKnuckle) * vn
                b.vx -= f * nx
                b.vy -= f * ny
                if vn < -0.02 {
                    events.append(PhysicsEvent.cushion(id: b.id, speed: -vn))
                }
            }
            b.x = kx + nx * rk
            b.y = ky + ny * rk
            hit = true
        }
        return hit
    }

    @inline(__always)
    private func cornerIndex(_ x: Double, _ y: Double) -> Int {
        let a: Int = x > 0.0 ? 2 : 0
        let c: Int = y > 0.0 ? 1 : 0
        return a + c
    }

    /// Flat cushion with inward normal (nx, ny); the ball centre is `pen` past the contact line.
    private func cushionHit(_ b: Ball, _ nx: Double, _ ny: Double, _ pen: Double, _ h: Double) -> Bool {
        let cushionH: Double = PoolConst.cushionH
        let ir2: Double = PoolConst.ir2
        let vx: Double = b.vx
        let vy: Double = b.vy
        let tx: Double = -ny
        let ty: Double = nx
        let vn: Double = vx * nx + vy * ny
        var vt: Double = vx * tx + vy * ty
        var wn: Double = b.wx * nx + b.wy * ny
        var wt: Double = b.wx * tx + b.wy * ty
        let un: Double = vn + cushionH * wt                 // normal speed of the contact point
        if un >= 0.0 {                                      // already leaving: just push out
            b.x += nx * pen
            b.y += ny * pen
            return false
        }
        var e: Double = 0.9 + 0.03 * un
        if e < 0.75 {
            e = 0.75
        }
        let jn: Double = -(1.0 + e) * un * PoolConst.kn
        let slip: Double = vt - PoolConst.R * b.wz - cushionH * wn
        var jt: Double = -slip * PoolConst.kt
        let lim: Double = PoolConst.muCushion * jn
        if jt > lim {
            jt = lim
        } else if jt < -lim {
            jt = -lim
        }
        let vnNew: Double = vn + jn
        vt += jt
        wt += jn * cushionH * ir2
        wn -= jt * cushionH * ir2
        b.wz -= PoolConst.cw * jt
        b.vx = vnNew * nx + vt * tx
        b.vy = vnNew * ny + vt * ty
        b.wx = wn * nx + wt * tx
        b.wy = wn * ny + wt * ty
        var tau: Double = vn < 0.0 ? -pen / vn : 0.0
        if tau > h {
            tau = h
        }
        b.x += (b.vx - vx) * tau
        b.y += (b.vy - vy) * tau
        let left: Double = pen - (vnNew - vn) * tau         // remaining penetration
        if left > 0.0 {
            b.x += nx * left
            b.y += ny * left
        }
        events.append(PhysicsEvent.cushion(id: b.id, speed: vn < 0.0 ? -vn : -un))
        return true
    }

    private func dropBall(_ b: Ball, _ idx: Int) {
        let sp: Double = sqrt(b.vx * b.vx + b.vy * b.vy)
        b.state = BallState.pocketed
        b.pocket = idx
        b.dropSpeed = sp
        if sp > 1e-6 {
            b.dropDirX = b.vx / sp
            b.dropDirY = b.vy / sp
        } else {
            b.dropDirX = 0.0
            b.dropDirY = 0.0
        }
        b.vx = 0.0
        b.vy = 0.0
        b.wx = 0.0
        b.wy = 0.0
        b.wz = 0.0
        flags[b.id] = false
        dirty = true
        events.append(PhysicsEvent.pocket(id: b.id, pocket: idx, speed: sp))
    }
}

// MARK: - Shot simulation

struct ShotOutcome {
    var firstHit: Int?
    var pocketed: [Int]
    var cuePocketed: Bool
    var railAfterContact: Bool
    var final: [(id: Int, x: Double, y: Double)]
    var time: Double
}

/// One simulated shot: a private `Physics` restored from a snapshot, struck, and stepped at a fixed `dt` until rest.
final class ShotSim {
    let phys: Physics
    let dt: Double
    let maxSteps: Int
    private(set) var steps: Int = 0
    private(set) var firstHit: Int? = nil
    private(set) var pocketed: [Int] = []
    private(set) var cuePocketed: Bool = false
    private(set) var railAfterContact: Bool = false
    private(set) var finalBalls: [(id: Int, x: Double, y: Double)] = []
    private(set) var time: Double = 0.0
    private(set) var done: Bool = false
    private var contact: Bool = false

    init(snapshot: BallSnapshot, angle: Double, speed: Double, side: Double = 0.0, top: Double = 0.0,
         maxTime: Double = 20.0, dt: Double = 1.0 / 120.0) {
        let p = Physics(empty: true)
        p.restore(snapshot)
        p.strike(angle: angle, speed: speed, side: side, top: top)
        self.phys = p
        self.dt = dt
        self.maxSteps = Int(maxTime / dt)
    }

    /// Run up to `nsteps` physics steps; returns true once the shot has come to rest.
    @discardableResult
    func advance(_ nsteps: Int) -> Bool {
        if done {
            return true
        }
        let p: Physics = phys
        var k: Int = 0
        while k < nsteps {
            k += 1
            p.step(dt)
            steps += 1
            if !p.events.isEmpty {
                for ev in p.events {
                    switch ev {
                    case .ballBall(let a, let b, _):
                        if !contact && (a == 0 || b == 0) {
                            contact = true
                            firstHit = (a == 0) ? b : a
                        }
                    case .cushion:
                        if contact {
                            railAfterContact = true
                        }
                    case .pocket(let id, _, _):
                        if id == 0 {
                            cuePocketed = true
                        } else {
                            pocketed.append(id)
                        }
                    case .cueHit:
                        break
                    }
                }
                p.events.removeAll(keepingCapacity: true)
            }
            if steps >= maxSteps || !p.moving() {
                done = true
                time = Double(steps) * dt
                var fin: [(id: Int, x: Double, y: Double)] = []
                for b in p.activeBalls() {
                    fin.append((id: b.id, x: b.x, y: b.y))
                }
                finalBalls = fin
                return true
            }
        }
        return false
    }

    func run() {
        while !advance(64) {
        }
    }

    var outcome: ShotOutcome {
        return ShotOutcome(firstHit: firstHit, pocketed: pocketed, cuePocketed: cuePocketed,
                           railAfterContact: railAfterContact, final: finalBalls, time: time)
    }
}

/// Play a shot from `s` to rest in a private `Physics` and return the outcome.
func simulateShot(_ s: BallSnapshot, angle: Double, speed: Double, side: Double, top: Double,
                  maxTime: Double = 20.0, dt: Double = 1.0 / 120.0) -> ShotOutcome {
    let sim = ShotSim(snapshot: s, angle: angle, speed: speed, side: side, top: top, maxTime: maxTime, dt: dt)
    sim.run()
    return sim.outcome
}
