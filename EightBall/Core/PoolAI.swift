import Foundation
import Dispatch

// Computer opponent for the 8-ball game: a port of pg_ai.py, time-sliced with an explicit state machine (Swift has no generators).
//
// AIPlanner.start() freezes the table; AIPlanner.step(budget:) is then called once per frame and does at most about `budget` seconds
// of work until it returns the shot.
//
// Planning: every legal target ball is paired with every pocket (ghost-ball aim, knuckle clearance, blocked paths, cut angle) and
// scored geometrically. 'easy' and 'medium' play the geometry with aim and speed noise; 'hard' additionally replays its best
// candidates with ShotSim (pot made, no scratch, no foul, cue ball left with a shot) and tries a little top/back spin for position.
// With no pot on, a safe shot (or a one-cushion kick when snookered) is played.

struct AIShot {
    var angle: Double
    var speed: Double
    var side: Double = 0.0
    var top: Double = 0.0
    var place: (x: Double, y: Double)? = nil
}

// MARK: - Internal data

/// Positions of the balls on the table (never the cue ball unless the caller adds it), ascending id, indexed by id.
struct AITable {
    var ids: [Int] = []
    var xs: [Double] = Array(repeating: 0.0, count: 16)
    var ys: [Double] = Array(repeating: 0.0, count: 16)
    var has: [Bool] = Array(repeating: false, count: 16)

    var isEmpty: Bool {
        return ids.isEmpty
    }

    mutating func add(_ id: Int, _ x: Double, _ y: Double) {
        ids.append(id)
        xs[id] = x
        ys[id] = y
        has[id] = true
    }
}

/// Object-ball side of one (target, pocket) pair.
struct AIRow {
    var tid: Int
    var tx: Double
    var ty: Double
    var gx: Double              // ghost ball
    var gy: Double
    var ux: Double              // unit vector target -> aim point
    var uy: Double
    var dtp: Double             // target -> aim point distance
    var clear: Double
    var k: Int                  // pocket index
    var entry: Double
}

/// A scored cue-ball approach to a row.
struct AICand {
    var score: Double
    var row: AIRow
    var angle: Double
    var dcg: Double
    var cut: Double
}

struct AIPocket {
    var x: Double
    var y: Double
    var axisX: Double
    var axisY: Double
    var k1x: Double             // the two knuckles nearest to the pocket
    var k1y: Double
    var k2x: Double
    var k2y: Double
}

/// Per difficulty: aim noise (rad), speed noise (fraction), chance to pick a bad ball, chance to take a random one of the best
/// candidates instead of the best.
struct AILevel {
    var aim: Double
    var speed: Double
    var badBall: Double
    var sloppy: Double
}

enum AIGeometry {
    static let pockets: [AIPocket] = AIGeometry.makePockets()
    static let aimShifts: [Double] = [0.0, 0.012, -0.012, 0.024, -0.024]   // aim points across the mouth
    static let cutMin: Double = 0.26                                        // cos of the largest cut angle (75 degrees)
    static let knuckleClear: Double = PoolConst.R + PoolConst.knuckleR

    static func level(_ d: Difficulty) -> AILevel {
        let deg: Double = Double.pi / 180.0
        switch d {
        case .easy:
            return AILevel(aim: 4.5 * deg, speed: 0.28, badBall: 0.25, sloppy: 0.5)
        case .medium:
            return AILevel(aim: 1.5 * deg, speed: 0.08, badBall: 0.0, sloppy: 0.0)
        case .hard:
            return AILevel(aim: 0.2 * deg, speed: 0.03, badBall: 0.0, sloppy: 0.0)
        }
    }

    private static func makePockets() -> [AIPocket] {
        let cpx: Double = PoolConst.cornerPocket.0
        let cpy: Double = PoolConst.cornerPocket.1
        let sideY: Double = PoolConst.sidePocketY
        var raw: [(Double, Double, Double, Double)] = []
        let signs: [(Double, Double)] = [(-1.0, -1.0), (-1.0, 1.0), (1.0, -1.0), (1.0, 1.0)]
        for s in signs {
            raw.append((s.0 * cpx, s.1 * cpy, -s.0 * 0.7071, -s.1 * 0.7071))
        }
        raw.append((0.0, -sideY, 0.0, 1.0))
        raw.append((0.0, sideY, 0.0, -1.0))
        let kxs: [Double] = PoolConst.knuckleX
        let kys: [Double] = PoolConst.knuckleY
        let n: Int = kxs.count
        var out: [AIPocket] = []
        for r in raw {
            var dist: [Double] = []
            for i in 0..<n {
                let dx: Double = kxs[i] - r.0
                let dy: Double = kys[i] - r.1
                dist.append(dx * dx + dy * dy)
            }
            let order: [Int] = aiStableOrder(dist, false)
            let a: Int = order[0]
            let b: Int = order[1]
            out.append(AIPocket(x: r.0, y: r.1, axisX: r.2, axisY: r.3,
                                k1x: kxs[a], k1y: kys[a], k2x: kxs[b], k2y: kys[b]))
        }
        return out
    }
}

/// Indices of `keys` sorted (ascending, or descending) with ties keeping their original order (a stable sort).
fileprivate func aiStableOrder(_ keys: [Double], _ descending: Bool) -> [Int] {
    var order: [Int] = []
    order.reserveCapacity(keys.count)
    for i in 0..<keys.count {
        order.append(i)
    }
    var a: Int = 1
    while a < order.count {
        let key: Int = order[a]
        let kv: Double = keys[key]
        var j: Int = a - 1
        while j >= 0 {
            let other: Double = keys[order[j]]
            let shift: Bool = descending ? (other < kv) : (other > kv)
            if !shift {
                break
            }
            order[j + 1] = order[j]
            j -= 1
        }
        order[j + 1] = key
        a += 1
    }
    return order
}

/// Squared distance from the point p to the segment a-b.
fileprivate func aiSegDist2(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
    let dx: Double = bx - ax
    let dy: Double = by - ay
    let l2: Double = dx * dx + dy * dy
    var t: Double = 0.0
    if l2 > 1e-12 {
        t = ((px - ax) * dx + (py - ay) * dy) / l2
    }
    if t < 0.0 {
        t = 0.0
    } else if t > 1.0 {
        t = 1.0
    }
    let ex: Double = ax + t * dx - px
    let ey: Double = ay + t * dy - py
    return ex * ex + ey * ey
}

/// Cue speed that gives the cue ball `ballSpeed` (inverse of Physics.strike).
fileprivate func aiCueSpeed(_ ballSpeed: Double, _ top: Double, _ side: Double) -> Double {
    return ballSpeed * (1.0 + PoolConst.mRatio + 2.5 * (top * top + side * side)) / 2.0
}

/// Cue speed for a pot: the object ball must reach the pocket with some pace.
fileprivate func aiPotSpeed(_ dcg: Double, _ dtp: Double, _ cut: Double) -> Double {
    let vObj: Double = sqrt(2.0 * 0.12 * dtp) + 0.6
    let vImp: Double = vObj / (0.97 * max(cut, 0.35))
    let vCue: Double = sqrt(vImp * vImp + 2.0 * 0.4 * dcg)
    return min(9.0, max(1.0, aiCueSpeed(vCue, 0.0, 0.0)))
}

@inline(__always)
fileprivate func aiNow() -> Double {
    return Double(DispatchTime.now().uptimeNanoseconds) * 1.0e-9
}

// MARK: - The planner

final class AIPlanner {
    private enum Phase {
        case idle           // not planning (or finished: `shot` holds the result)
        case begin          // nothing done yet
        case placing        // ball in hand: scoring the candidate spots
        case placed         // the cue ball position is decided
        case choose         // pick a shot
        case verifying      // hard: replaying candidates in the physics engine
    }

    private let difficulty: Difficulty
    private let level: AILevel
    private var rng: SplitMix64
    private var phase: Phase = Phase.idle
    private var shot: AIShot? = nil
    private var deadline: Double = 0.0

    // frozen table
    private var snap: BallSnapshot
    private var targetList: [Int] = []
    private var isTarget: [Bool] = Array(repeating: false, count: 16)
    private var breakFlag: Bool = false
    private var hand: Bool = false
    private var kitchen: Bool = false
    private var pos: AITable = AITable()
    private var cueX: Double = 0.0
    private var cueY: Double = 0.0

    // ball in hand
    private var hasPlace: Bool = false
    private var placeX: Double = 0.0
    private var placeY: Double = 0.0
    private var spotXs: [Double] = []
    private var spotYs: [Double] = []
    private var spotIndex: Int = 0
    private var placeRows: [AIRow] = []
    private var bestSpot: Int = 0
    private var bestSpotVal: Double = -1e9

    // hard: verification
    private var trialCands: [AICand] = []
    private var trialShots: [AIShot] = []
    private var trialIndex: Int = 0
    private var verifyStage: Int = 0
    private var safeShots: [AIShot] = []
    private var safeIndex: Int = 0
    private var bestVal: Double = -1e9
    private var bestShot: AIShot? = nil
    private var hasPotVal: Bool = false
    private var replaySim: ShotSim? = nil

    init(difficulty: Difficulty) {
        self.difficulty = difficulty
        self.level = AIGeometry.level(difficulty)
        self.rng = SplitMix64(seed: 0)
        self.snap = BallSnapshot(balls: [])
    }

    // MARK: driving

    /// Begin planning a shot for `player` from the current table state.
    func start(physics: Physics, rules: EightBallRules, player: Int, seed: UInt64? = nil) {
        rng = SplitMix64(seed: seed ?? SplitMix64.randomSeed())
        snap = physics.snapshot()
        let targets: Set<Int> = rules.legalTargets(player: player, physics: physics)
        targetList = targets.sorted()
        isTarget = Array(repeating: false, count: 16)
        for t in targetList {
            if t >= 0 && t < 16 {
                isTarget[t] = true
            }
        }
        breakFlag = rules.breakShot
        hand = rules.ballInHand
        kitchen = breakFlag || rules.kitchenOnly
        shot = nil
        hasPlace = false
        replaySim = nil
        phase = Phase.begin
    }

    /// Work for about `budget` seconds; returns nil while thinking, then the shot.
    func step(budget: Double = 0.004) -> AIShot? {
        if phase == Phase.idle {
            return shot
        }
        deadline = aiNow() + budget
        if run() {
            return shot
        }
        return nil
    }

    private func late() -> Bool {
        return aiNow() >= deadline
    }

    /// Runs the state machine until it is done (true) or the time slice is used up (false).
    private func run() -> Bool {
        while true {
            switch phase {
            case .idle:
                return true
            case .begin:
                beginPlan()
            case .placing:
                if !placementStep() {
                    return false
                }
                phase = Phase.placed
            case .placed:
                finishPlacement()
            case .choose:
                beginChoose()
            case .verifying:
                if !verifyStep() {
                    return false
                }
                finishVerify()
            }
        }
    }

    // MARK: planning

    private func makeShot(_ angle: Double, _ speed: Double, _ side: Double, _ top: Double) -> AIShot {
        return AIShot(angle: angle, speed: speed, side: side, top: top, place: nil)
    }

    private func finish(_ s: AIShot) {
        var out: AIShot = s
        if hasPlace {
            out.place = (x: placeX, y: placeY)
        } else {
            out.place = nil
        }
        shot = out
        phase = Phase.idle
    }

    private func beginPlan() {
        pos = AITable()
        for i in 1..<16 {
            let rec: BallRecord = snap.balls[i]
            if rec.state == BallState.active {
                pos.add(i, rec.x, rec.y)
            }
        }
        hasPlace = false
        if snap.balls[0].state != BallState.active {
            hand = true
        }
        if hand {
            if setupPlacement() {
                phase = Phase.placed
            } else {
                phase = Phase.placing
            }
        } else {
            phase = Phase.placed
        }
    }

    private func finishPlacement() {
        if hasPlace {
            let ph = Physics(empty: true)
            ph.restore(snap)
            ph.placeBall(0, x: placeX, y: placeY)
            snap = ph.snapshot()
        }
        cueX = snap.balls[0].x
        cueY = snap.balls[0].y
        if pos.isEmpty {
            finish(makeShot(0.0, 2.0, 0.0, 0.0))
            return
        }
        if breakFlag {
            finish(breakShotPlan())
            return
        }
        phase = Phase.choose
    }

    private func noisy(_ s: inout AIShot) {
        s.angle += rng.gauss(0.0, level.aim)
        let f: Double = max(0.5, 1.0 + rng.gauss(0.0, level.speed))
        s.speed = min(12.0, max(0.5, s.speed * f))
    }

    private func breakShotPlan() -> AIShot {
        var head: Int = pos.ids[0]
        var headD: Double = Double.greatestFiniteMagnitude
        for id in pos.ids {
            let dx: Double = pos.xs[id] - cueX
            let dy: Double = pos.ys[id] - cueY
            let d: Double = dx * dx + dy * dy
            if d < headD {
                headD = d
                head = id
            }
        }
        let angle: Double = atan2(pos.ys[head] - cueY, pos.xs[head] - cueX)
        let ballSpeed: Double = (difficulty == Difficulty.easy) ? 6.8 : 8.5     // m/s off the tip
        var s: AIShot = makeShot(angle, aiCueSpeed(ballSpeed, 0.0, 0.0), 0.0, 0.0)
        let minAim: Double = 0.4 * Double.pi / 180.0
        s.angle += rng.gauss(0.0, max(level.aim, minAim))
        s.speed *= 1.0 + rng.uniform(-0.04, 0.04)
        return s
    }

    // MARK: ball in hand

    /// Returns true when the spot is already decided (placeX / placeY set), false when `placementStep` has to score the spots.
    private func setupPlacement() -> Bool {
        hasPlace = true
        if breakFlag {
            placeX = PoolConst.headX - 0.06
            placeY = rng.uniform(-0.08, 0.08)
            return true
        }
        let xs: [Double]
        if kitchen {
            xs = [-1.15, -1.0, -0.85, -0.7]
        } else {
            xs = [-1.05, -0.8, -0.55, -0.3, 0.0, 0.3, 0.55, 0.8, 1.05]
        }
        let ys: [Double] = [-0.5, -0.25, 0.0, 0.25, 0.5]
        let dLim: Double = PoolConst.D + 0.02
        let lim: Double = dLim * dLim
        spotXs = []
        spotYs = []
        for x in xs {
            for y in ys {
                var ok: Bool = true
                for id in pos.ids {
                    let dx: Double = x - pos.xs[id]
                    let dy: Double = y - pos.ys[id]
                    if !(dx * dx + dy * dy > lim) {
                        ok = false
                        break
                    }
                }
                if ok {
                    spotXs.append(x)
                    spotYs.append(y)
                }
            }
        }
        if spotXs.isEmpty {
            placeX = PoolConst.headX - 0.06
            placeY = 0.0
            return true
        }
        if difficulty == Difficulty.easy && rng.nextUnit() < 0.6 {
            let k: Int = rng.index(spotXs.count)
            placeX = spotXs[k]
            placeY = spotYs[k]
            return true
        }
        placeRows = prepare(pos, targetList)
        bestSpot = 0
        bestSpotVal = -1e9
        spotIndex = 0
        return false
    }

    /// Scores spots until done (true) or late (false).
    private func placementStep() -> Bool {
        while spotIndex < spotXs.count {
            let sx: Double = spotXs[spotIndex]
            let sy: Double = spotYs[spotIndex]
            let cands: [AICand] = evaluate(placeRows, sx, sy, pos)
            var val: Double = -20.0
            if !cands.isEmpty {
                val = cands[0].score
            }
            val -= 0.15 * abs(sy)
            if val > bestSpotVal {
                bestSpot = spotIndex
                bestSpotVal = val
            }
            spotIndex += 1
            if spotIndex < spotXs.count && late() {
                return false
            }
        }
        placeX = spotXs[bestSpot]
        placeY = spotYs[bestSpot]
        return true
    }

    // MARK: shot geometry

    /// Object-ball side of every (target, pocket) pair: ghost ball, aim and clearance.
    private func prepare(_ table: AITable, _ targets: [Int]) -> [AIRow] {
        var rows: [AIRow] = []
        let pockets: [AIPocket] = AIGeometry.pockets
        let shifts: [Double] = AIGeometry.aimShifts
        let dd: Double = PoolConst.D
        let rr: Double = PoolConst.R
        let hl: Double = PoolConst.HL
        let hw: Double = PoolConst.HW
        let kClear: Double = AIGeometry.knuckleClear
        let lim: Double = (dd - 0.003) * (dd - 0.003)
        for tid in targets {
            if !table.has[tid] {
                continue
            }
            let tx: Double = table.xs[tid]
            let ty: Double = table.ys[tid]
            for k in 0..<pockets.count {
                let pk: AIPocket = pockets[k]
                var haveBest: Bool = false
                var bClear: Double = 0.0
                var bGx: Double = 0.0
                var bGy: Double = 0.0
                var bUx: Double = 0.0
                var bUy: Double = 0.0
                var bDtp: Double = 0.0
                var bEntry: Double = 0.0
                for s in shifts {
                    let ax: Double = pk.x - pk.axisY * s
                    let ay: Double = pk.y + pk.axisX * s
                    let dx: Double = ax - tx
                    let dy: Double = ay - ty
                    let dtp: Double = hypot(dx, dy)
                    if dtp < dd {
                        continue
                    }
                    let ux: Double = dx / dtp
                    let uy: Double = dy / dtp
                    let c1: Double = aiSegDist2(pk.k1x, pk.k1y, tx, ty, ax, ay)
                    let c2: Double = aiSegDist2(pk.k2x, pk.k2y, tx, ty, ax, ay)
                    var clear: Double = sqrt(min(c1, c2))
                    clear -= kClear
                    if clear < 0.004 || (haveBest && clear <= bClear + 0.004) {
                        continue
                    }
                    let gx: Double = tx - dd * ux
                    let gy: Double = ty - dd * uy
                    if abs(gx) > hl - rr - 0.005 || abs(gy) > hw - rr - 0.005 {
                        continue
                    }
                    var blocked: Bool = false
                    for oid in table.ids {
                        if oid == tid {
                            continue
                        }
                        if aiSegDist2(table.xs[oid], table.ys[oid], tx, ty, ax, ay) < lim {
                            blocked = true
                            break
                        }
                    }
                    if blocked {
                        continue
                    }
                    haveBest = true
                    bClear = clear
                    bGx = gx
                    bGy = gy
                    bUx = ux
                    bUy = uy
                    bDtp = dtp
                    bEntry = ux * pk.axisX + uy * pk.axisY
                }
                if haveBest {
                    let row = AIRow(tid: tid, tx: tx, ty: ty, gx: bGx, gy: bGy, ux: bUx, uy: bUy,
                                    dtp: bDtp, clear: min(bClear, 0.03), k: k, entry: bEntry)
                    rows.append(row)
                }
            }
        }
        return rows
    }

    /// Cue-ball side: rows -> candidates sorted best first.
    private func evaluate(_ rows: [AIRow], _ cx: Double, _ cy: Double, _ table: AITable) -> [AICand] {
        var out: [AICand] = []
        let dd: Double = PoolConst.D
        let dd2: Double = PoolConst.D2
        let lim: Double = (dd - 0.002) * (dd - 0.002)
        let pockets: [AIPocket] = AIGeometry.pockets
        for row in rows {
            let wx: Double = row.gx - cx
            let wy: Double = row.gy - cy
            let dcg: Double = hypot(wx, wy)
            let tcx: Double = row.tx - cx
            let tcy: Double = row.ty - cy
            if dcg < 1e-3 || tcx * tcx + tcy * tcy < dd2 {
                continue
            }
            let cut: Double = (wx * row.ux + wy * row.uy) / dcg
            if cut < AIGeometry.cutMin {
                continue
            }
            var blocked: Bool = false
            for oid in table.ids {
                if oid == row.tid {
                    continue
                }
                if aiSegDist2(table.xs[oid], table.ys[oid], cx, cy, row.gx, row.gy) < lim {
                    blocked = true
                    break
                }
            }
            if blocked {
                continue
            }
            let cut15: Double = pow(cut, 1.5)
            let travel: Double = dcg + 1.6 * row.dtp
            var score: Double = -travel / cut15
            score += 25.0 * row.clear
            score -= 1.5 * (1.0 - row.entry)
            if cut < 0.97 {                                 // cue ball tends to leave along the tangent line
                let tnx: Double = wx / dcg - row.ux * cut
                let tny: Double = wy / dcg - row.uy * cut
                let tl: Double = hypot(tnx, tny)
                for pk in pockets {
                    let pdx: Double = pk.x - row.gx
                    let pdy: Double = pk.y - row.gy
                    let along: Double = (pdx * tnx + pdy * tny) / tl
                    let across: Double = abs(pdx * tny - pdy * tnx) / tl
                    if along > 0.0 && along < 1.0 && across < 0.09 {
                        score -= 1.5
                        break
                    }
                }
            }
            out.append(AICand(score: score, row: row, angle: atan2(wy, wx), dcg: dcg, cut: cut))
        }
        if out.count < 2 {
            return out
        }
        var keys: [Double] = []
        keys.reserveCapacity(out.count)
        for c in out {
            keys.append(c.score)
        }
        let order: [Int] = aiStableOrder(keys, true)
        var result: [AICand] = []
        result.reserveCapacity(out.count)
        for i in order {
            result.append(out[i])
        }
        return result
    }

    private func potShot(_ cand: AICand, _ top: Double, _ speedMult: Double) -> AIShot {
        let sp: Double = aiPotSpeed(cand.dcg, cand.row.dtp, cand.cut) * speedMult
        return makeShot(cand.angle, sp, 0.0, top)
    }

    // MARK: safe / kick shots

    /// True if no ball other than `tid` blocks the path a -> b of the cue ball.
    private func pathClear(_ table: AITable, _ tid: Int, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Bool {
        let dd: Double = PoolConst.D
        let lim: Double = (dd - 0.002) * (dd - 0.002)
        for oid in table.ids {
            if oid == tid {
                continue
            }
            if aiSegDist2(table.xs[oid], table.ys[oid], ax, ay, bx, by) < lim {
                return false
            }
        }
        return true
    }

    /// Soft hits on unblocked legal balls, else one-cushion kicks; nearest first. Never empty.
    private func safeCandidates(_ table: AITable, _ cx: Double, _ cy: Double) -> [AIShot] {
        let hl: Double = PoolConst.HL
        let hw: Double = PoolConst.HW
        let rr: Double = PoolConst.R
        var directD: [Double] = []
        var directS: [AIShot] = []
        var kickD: [Double] = []
        var kickS: [AIShot] = []
        for tid in targetList {
            if !table.has[tid] {
                continue
            }
            let tx: Double = table.xs[tid]
            let ty: Double = table.ys[tid]
            if pathClear(table, tid, cx, cy, tx, ty) {
                let angle: Double = atan2(ty - cy, tx - cx)
                let dist: Double = hypot(tx - cx, ty - cy)
                let sp: Double = safeSpeed(table, tid, angle, dist)
                directD.append(dist)
                directS.append(makeShot(angle, sp, 0.0, 0.0))
                continue
            }
            let flags: [Bool] = [true, false]
            let signs: [Double] = [1.0, -1.0]
            for horizontal in flags {
                for sign in signs {
                    let line: Double = sign * ((horizontal ? hw : hl) - rr)     // cushion line for ball centres
                    let ix: Double = horizontal ? tx : (2.0 * line - tx)
                    let iy: Double = horizontal ? (2.0 * line - ty) : ty
                    let span: Double = horizontal ? (iy - cy) : (ix - cx)
                    if abs(span) < 1e-6 {
                        continue
                    }
                    let num: Double = horizontal ? (line - cy) : (line - cx)
                    let f: Double = num / span
                    let bx: Double = cx + f * (ix - cx)
                    let by: Double = cy + f * (iy - cy)
                    if !(f > 0.0 && f < 1.0) || abs(bx) > hl - 0.1 || abs(by) > hw - 0.1 {
                        continue
                    }
                    if !(pathClear(table, tid, cx, cy, bx, by) && pathClear(table, tid, bx, by, tx, ty)) {
                        continue
                    }
                    let length: Double = hypot(bx - cx, by - cy) + hypot(tx - bx, ty - by)
                    kickD.append(length)
                    kickS.append(makeShot(atan2(iy - cy, ix - cx), min(9.0, 2.0 + 2.2 * length), 0.0, 0.0))
                }
            }
        }
        var out: [AIShot] = []
        for i in aiStableOrder(directD, false) {
            out.append(directS[i])
        }
        for i in aiStableOrder(kickD, false) {
            out.append(kickS[i])
        }
        if out.isEmpty {                                    // snookered with no kick: aim at the nearest ball
            var pool: [Int] = []
            for t in targetList {
                if table.has[t] {
                    pool.append(t)
                }
            }
            if pool.isEmpty {
                pool = table.ids
            }
            var near: Int = pool[0]
            var nearD: Double = Double.greatestFiniteMagnitude
            for t in pool {
                let dx: Double = table.xs[t] - cx
                let dy: Double = table.ys[t] - cy
                let d: Double = dx * dx + dy * dy
                if d < nearD {
                    nearD = d
                    near = t
                }
            }
            out.append(makeShot(atan2(table.ys[near] - cy, table.xs[near] - cx), 3.0, 0.0, 0.0))
        }
        return out
    }

    /// Soft hit, but hard enough for the object ball to reach a cushion.
    private func safeSpeed(_ table: AITable, _ tid: Int, _ angle: Double, _ dist: Double) -> Double {
        let dx: Double = cos(angle)
        let dy: Double = sin(angle)
        let tx: Double = table.xs[tid]
        let ty: Double = table.ys[tid]
        let hl: Double = PoolConst.HL
        let hw: Double = PoolConst.HW
        let rr: Double = PoolConst.R
        var rail: Double = 9.0
        if abs(dx) > 1e-6 {
            let edgeX: Double = dx > 0.0 ? (hl - rr) : -(hl - rr)
            rail = min(rail, (edgeX - tx) / dx)
        }
        if abs(dy) > 1e-6 {
            let edgeY: Double = dy > 0.0 ? (hw - rr) : -(hw - rr)
            rail = min(rail, (edgeY - ty) / dy)
        }
        let vObj: Double = sqrt(2.0 * 0.13 * (max(rail, 0.0) + 0.25)) + 0.15
        let q: Double = vObj / 0.97
        let vCue: Double = sqrt(q * q + 2.0 * 0.4 * dist)
        return min(6.0, max(1.2, aiCueSpeed(vCue, 0.0, 0.0)))
    }

    // MARK: shot choice

    private func beginChoose() {
        let rows: [AIRow] = prepare(pos, targetList)
        let cands: [AICand] = evaluate(rows, cueX, cueY, pos)
        var pending: AIShot? = nil
        if difficulty == Difficulty.easy && rng.nextUnit() < level.badBall {
            let tid: Int = pos.ids[rng.index(pos.ids.count)]
            let ang: Double = atan2(pos.ys[tid] - cueY, pos.xs[tid] - cueX)
            let sp: Double = rng.uniform(1.5, 4.5)
            pending = makeShot(ang, sp, 0.0, 0.0)
        } else if difficulty == Difficulty.hard {
            startVerify(cands)
            phase = Phase.verifying
            return
        } else if !cands.isEmpty && (difficulty == Difficulty.easy || cands[0].score > -9.0) {
            var pick: AICand = cands[0]
            if rng.nextUnit() < level.sloppy {
                let n: Int = min(3, cands.count)
                pick = cands[rng.index(n)]
            }
            pending = potShot(pick, 0.0, 1.0)
        }
        var s: AIShot
        if let p = pending {
            s = p
        } else {
            s = safeCandidates(pos, cueX, cueY)[0]
        }
        noisy(&s)
        finish(s)
    }

    private func startVerify(_ cands: [AICand]) {
        trialCands = []
        trialShots = []
        let n: Int = min(4, cands.count)
        for i in 0..<n {
            trialCands.append(cands[i])
            trialShots.append(potShot(cands[i], 0.0, 1.0))
        }
        trialIndex = 0
        verifyStage = 0
        safeShots = []
        safeIndex = 0
        bestVal = -1e9
        bestShot = nil
        hasPotVal = false
        replaySim = nil
    }

    /// Hard AI: replays the best candidates in the physics engine and keeps the best outcome. True when finished, false when late.
    private func verifyStep() -> Bool {
        while true {
            if verifyStage == 0 {
                if trialIndex >= trialShots.count {
                    if bestVal < 90.0 {
                        let all: [AIShot] = safeCandidates(pos, cueX, cueY)
                        safeShots = Array(all.prefix(3))
                        safeIndex = 0
                        verifyStage = 1
                        continue
                    }
                    return true
                }
                let trial: AIShot = trialShots[trialIndex]
                if replaySim == nil {
                    replaySim = makeSim(trial)
                }
                guard let val = replayStep() else {
                    return false
                }
                let cand: AICand = trialCands[trialIndex]
                trialIndex += 1
                if val > bestVal {
                    bestVal = val
                    bestShot = trial
                    if val >= 90.0 && !hasPotVal {
                        hasPotVal = true
                        let tops: [Double] = [-0.3, 0.3, 0.0, -0.3]
                        let mults: [Double] = [1.0, 1.0, 0.75, 1.3]
                        for j in 0..<tops.count {
                            trialCands.append(cand)
                            trialShots.append(potShot(cand, tops[j], mults[j]))
                        }
                    }
                }
            } else {
                if safeIndex >= safeShots.count {
                    return true
                }
                let trial: AIShot = safeShots[safeIndex]
                if replaySim == nil {
                    replaySim = makeSim(trial)
                }
                guard let val = replayStep() else {
                    return false
                }
                safeIndex += 1
                if val > bestVal {
                    bestVal = val
                    bestShot = trial
                }
            }
        }
    }

    private func finishVerify() {
        var s: AIShot
        if let b = bestShot {
            s = b
        } else {
            s = safeCandidates(pos, cueX, cueY)[0]
        }
        noisy(&s)
        finish(s)
    }

    private func makeSim(_ s: AIShot) -> ShotSim {
        return ShotSim(snapshot: snap, angle: s.angle, speed: s.speed, side: s.side, top: s.top,
                       maxTime: 15.0, dt: 1.0 / 60.0)
    }

    /// Advances the current replay; returns its value when it has come to rest, nil when the time slice ran out.
    private func replayStep() -> Double? {
        guard let sim = replaySim else {
            return 0.0
        }
        while true {
            if sim.advance(2) {
                replaySim = nil
                return value(sim)
            }
            if late() {
                return nil
            }
        }
    }

    /// Outcome of a simulated shot for the shooter (higher is better).
    private func value(_ sim: ShotSim) -> Double {
        var firstOK: Bool = false
        if let f = sim.firstHit {
            if f >= 0 && f < 16 {
                firstOK = isTarget[f]
            }
        }
        let anyPocketed: Bool = !sim.pocketed.isEmpty
        let onlyEight: Bool = targetList.count == 1 && targetList[0] == 8
        let foul: Bool = sim.cuePocketed || !firstOK || (!anyPocketed && !sim.railAfterContact)
        var val: Double = sim.cuePocketed ? -200.0 : 0.0
        if !firstOK {
            val -= 150.0
        } else if !anyPocketed && !sim.railAfterContact {
            val -= 100.0
        }
        var anyTarget: Bool = false
        for i in sim.pocketed {
            if i == 8 {
                val += (onlyEight && !foul) ? 1000.0 : -1000.0
            } else if isTarget[i] {
                val += 100.0
            } else {
                val -= 20.0
            }
            if isTarget[i] {
                anyTarget = true
            }
        }
        if foul {
            return val
        }
        val += 5.0
        if anyTarget {
            var after = AITable()
            var haveCue: Bool = false
            var cx: Double = 0.0
            var cy: Double = 0.0
            for rec in sim.finalBalls {
                if rec.id == 0 {
                    haveCue = true
                    cx = rec.x
                    cy = rec.y
                } else {
                    after.add(rec.id, rec.x, rec.y)
                }
            }
            var left: [Int] = []
            for t in targetList {
                if after.has[t] {
                    left.append(t)
                }
            }
            if left.isEmpty && after.has[8] {
                left = [8]
            }
            if !left.isEmpty && haveCue {
                let cands: [AICand] = evaluate(prepare(after, left), cx, cy, after)
                if cands.isEmpty {
                    val -= 5.0
                } else {
                    val += 12.0 + max(-12.0, cands[0].score)
                }
            }
        }
        return val
    }
}
