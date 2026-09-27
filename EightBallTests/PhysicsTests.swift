import XCTest
@testable import EightBall

/// Replays the scenarios recorded from the Python engine (golden.json, made by tools/make_golden.py) and checks the physics
/// against the behaviour tests of the Python game (tools/test_pool.py).
final class PhysicsTests: XCTestCase {

    private let positionTolerance: Double = 2e-3

    // MARK: golden data

    private struct GoldenScenario {
        var name: String
        var balls: [(id: Int, x: Double, y: Double)]
        var angle: Double
        var speed: Double
        var side: Double
        var top: Double
        var firstHit: Int?
        var pocketed: [Int]
        var pocketIndices: [Int]
        var cuePocketed: Bool
        var finalPositions: [Int: (x: Double, y: Double)]
    }

    private func number(_ v: Any?) -> Double {
        if let n = v as? NSNumber {
            return n.doubleValue
        }
        return 0.0
    }

    private func integer(_ v: Any?) -> Int {
        if let n = v as? NSNumber {
            return n.intValue
        }
        return 0
    }

    private func loadGolden() throws -> (dt: Double, maxSteps: Int, scenarios: [GoldenScenario]) {
        let bundle = Bundle(for: type(of: self))
        let url: URL = try XCTUnwrap(bundle.url(forResource: "golden", withExtension: "json"), "golden.json is not in the test bundle")
        let data: Data = try Data(contentsOf: url)
        let obj: Any = try JSONSerialization.jsonObject(with: data, options: [])
        let root: [String: Any] = try XCTUnwrap(obj as? [String: Any])
        let list: [[String: Any]] = try XCTUnwrap(root["scenarios"] as? [[String: Any]])
        var out: [GoldenScenario] = []
        for item in list {
            let name: String = (item["name"] as? String) ?? "?"
            var balls: [(id: Int, x: Double, y: Double)] = []
            let rows: [[Any]] = (item["balls"] as? [[Any]]) ?? []
            for row in rows {
                balls.append((id: integer(row[0]), x: number(row[1]), y: number(row[2])))
            }
            let strike: [String: Any] = (item["strike"] as? [String: Any]) ?? [:]
            let expect: [String: Any] = (item["expect"] as? [String: Any]) ?? [:]
            var firstHit: Int? = nil
            if let fh = expect["first_hit"] as? NSNumber {
                firstHit = fh.intValue
            }
            var pocketed: [Int] = []
            for v in (expect["pocketed"] as? [Any]) ?? [] {
                pocketed.append(integer(v))
            }
            var pocketIndices: [Int] = []
            for pr in (expect["pockets"] as? [[Any]]) ?? [] {
                pocketIndices.append(integer(pr[1]))
            }
            var finals: [Int: (x: Double, y: Double)] = [:]
            for f in (expect["final"] as? [[String: Any]]) ?? [] {
                finals[integer(f["id"])] = (x: number(f["x"]), y: number(f["y"]))
            }
            let cueP: Bool = (expect["cue_pocketed"] as? NSNumber)?.boolValue ?? false
            out.append(GoldenScenario(name: name, balls: balls, angle: number(strike["angle"]), speed: number(strike["speed"]),
                                      side: number(strike["side"]), top: number(strike["top"]), firstHit: firstHit,
                                      pocketed: pocketed, pocketIndices: pocketIndices, cuePocketed: cueP,
                                      finalPositions: finals))
        }
        return (dt: number(root["dt"]), maxSteps: integer(root["maxSteps"]), scenarios: out)
    }

    /// Physics with only the listed balls on the cloth (Python: Physics(empty=True) + place_ball, the others off the table).
    private func table(_ balls: [(id: Int, x: Double, y: Double)]) -> Physics {
        let p = Physics(empty: true)
        for b in p.balls {
            b.state = BallState.pocketed
        }
        for b in balls {
            p.placeBall(b.id, x: b.x, y: b.y)
        }
        return p
    }

    private func compareFinal(_ name: String, _ expected: [Int: (x: Double, y: Double)], _ actual: [(id: Int, x: Double, y: Double)]) {
        XCTAssertEqual(actual.count, expected.count, "\(name): number of balls left on the table")
        for a in actual {
            if let e = expected[a.id] {
                XCTAssertEqual(a.x, e.x, accuracy: positionTolerance, "\(name): ball \(a.id) x")
                XCTAssertEqual(a.y, e.y, accuracy: positionTolerance, "\(name): ball \(a.id) y")
            } else {
                XCTFail("\(name): ball \(a.id) should not be on the table")
            }
        }
    }

    // MARK: golden replays

    func testGoldenScenariosStepByStep() throws {
        let golden = try loadGolden()
        XCTAssertGreaterThanOrEqual(golden.scenarios.count, 8)
        for sc in golden.scenarios {
            let p: Physics = table(sc.balls)
            p.strike(angle: sc.angle, speed: sc.speed, side: sc.side, top: sc.top)
            var firstHit: Int? = nil
            var pocketed: [Int] = []
            var pocketIndices: [Int] = []
            var cuePocketed: Bool = false
            var steps: Int = 0
            while steps < golden.maxSteps {
                p.step(golden.dt)
                steps += 1
                for ev in p.events {
                    switch ev {
                    case .ballBall(let a, let b, _):
                        if firstHit == nil && (a == 0 || b == 0) {
                            firstHit = (a == 0) ? b : a
                        }
                    case .pocket(let id, let idx, _):
                        if id == 0 {
                            cuePocketed = true
                        } else {
                            pocketed.append(id)
                        }
                        pocketIndices.append(idx)
                    case .cushion:
                        break
                    case .cueHit:
                        break
                    }
                }
                p.events.removeAll()
                if !p.moving() {
                    break
                }
            }
            XCTAssertEqual(firstHit, sc.firstHit, "\(sc.name): first ball hit")
            XCTAssertEqual(pocketed, sc.pocketed, "\(sc.name): pocketed ids")
            XCTAssertEqual(pocketIndices, sc.pocketIndices, "\(sc.name): pockets used")
            XCTAssertEqual(cuePocketed, sc.cuePocketed, "\(sc.name): cue ball pocketed")
            var actual: [(id: Int, x: Double, y: Double)] = []
            for b in p.activeBalls() {
                actual.append((id: b.id, x: b.x, y: b.y))
            }
            compareFinal(sc.name, sc.finalPositions, actual)
        }
    }

    func testGoldenScenariosThroughShotSim() throws {
        let golden = try loadGolden()
        for sc in golden.scenarios {
            let p: Physics = table(sc.balls)
            let out: ShotOutcome = simulateShot(p.snapshot(), angle: sc.angle, speed: sc.speed, side: sc.side, top: sc.top,
                                                maxTime: 60.0, dt: golden.dt)
            XCTAssertEqual(out.firstHit, sc.firstHit, "\(sc.name): first ball hit")
            XCTAssertEqual(out.pocketed, sc.pocketed, "\(sc.name): pocketed ids")
            XCTAssertEqual(out.cuePocketed, sc.cuePocketed, "\(sc.name): cue ball pocketed")
            compareFinal(sc.name, sc.finalPositions, out.final)
        }
    }

    func testFastSidePocketShotDrops() throws {
        let golden = try loadGolden()
        var found: Bool = false
        for sc in golden.scenarios {
            if sc.name == "side_pocket_fast" {
                found = true
                XCTAssertEqual(sc.pocketed, [9])
                XCTAssertEqual(sc.pocketIndices.first, 5)
            }
        }
        XCTAssertTrue(found)
    }

    // MARK: behaviour tests (test_pool.py)

    private func runToRest(_ p: Physics, limit: Double = 60.0) {
        var t: Double = 0.0
        let dt: Double = 1.0 / 120.0
        while p.moving() && t < limit {
            p.step(dt)
            t += dt
        }
    }

    private func minGap(_ p: Physics) -> Double {
        let act: [Ball] = p.activeBalls()
        var best: Double = 9.0
        for i in 0..<act.count {
            var j: Int = i + 1
            while j < act.count {
                let d: Double = hypot(act[i].x - act[j].x, act[i].y - act[j].y)
                if d < best {
                    best = d
                }
                j += 1
            }
        }
        return best
    }

    func testRackGeometry() {
        let seeds: [UInt64] = [0, 1, 2, 99]
        for seed in seeds {
            let p = Physics()
            p.rack(seed: seed)
            let b: [Ball] = p.balls
            XCTAssertGreaterThanOrEqual(minGap(p), PoolConst.D, "rack balls overlap")
            XCTAssertLessThan(minGap(p), PoolConst.D + 3e-4, "rack is not tight")
            var apex: Ball = b[1]
            for i in 1..<16 {
                if b[i].x < apex.x {
                    apex = b[i]
                }
            }
            XCTAssertEqual(apex.x, PoolConst.footX, accuracy: 1e-9)
            XCTAssertEqual(apex.y, 0.0, accuracy: 1e-9)
            XCTAssertEqual(b[8].y, 0.0, accuracy: 1e-9, "8 not on the centre line")
            var rowsX: [Double] = []
            for i in 1..<16 {
                var known: Bool = false
                for rx in rowsX {
                    if abs(rx - b[i].x) < 1e-6 {
                        known = true
                    }
                }
                if !known {
                    rowsX.append(b[i].x)
                }
            }
            rowsX.sort()
            guard rowsX.count == 5 else {
                XCTFail("the rack must have five rows")
                return
            }
            XCTAssertEqual(b[8].x, rowsX[2], accuracy: 1e-6, "8 not in the middle row")
            // back row: one solid and one stripe in the two corners
            var back: [Ball] = []
            for i in 1..<16 {
                if abs(b[i].x - rowsX[4]) < 1e-6 {
                    back.append(b[i])
                }
            }
            back.sort { $0.y < $1.y }
            guard back.count == 5 else {
                XCTFail("the back row must have five balls")
                return
            }
            XCTAssertNotEqual(back[0].id < 8, back[4].id < 8, "back corners are not one solid and one stripe")
            XCTAssertEqual(b[0].x, PoolConst.headX, accuracy: 1e-12)
            XCTAssertEqual(b[0].y, 0.0, accuracy: 1e-12)
            XCTAssertFalse(p.moving())
            XCTAssertEqual(p.activeBalls().count, 16)
        }
    }

    func testRackSeedsDiffer() {
        let a = Physics()
        a.rack(seed: 1)
        let b = Physics()
        b.rack(seed: 2)
        var same: Bool = true
        for i in 0..<16 {
            if a.balls[i].x != b.balls[i].x || a.balls[i].y != b.balls[i].y {
                same = false
            }
        }
        XCTAssertFalse(same)
        let c = Physics()
        c.rack(seed: 1)
        for i in 0..<16 {
            XCTAssertEqual(a.balls[i].x, c.balls[i].x)
            XCTAssertEqual(a.balls[i].y, c.balls[i].y)
        }
    }

    func testPotAndSpin() {
        // straight stun shot into the top-right corner pocket
        let px: Double = PoolConst.cornerPocket.0
        let py: Double = PoolConst.cornerPocket.1
        var ux: Double = px - 0.9
        var uy: Double = py - 0.42
        let d: Double = hypot(ux, uy)
        ux /= d
        uy /= d
        let p = table([(id: 1, x: 0.9, y: 0.42), (id: 0, x: 0.9 - 0.5 * ux, y: 0.42 - 0.5 * uy)])
        p.strike(angle: atan2(uy, ux), speed: 2.2, side: 0.0, top: 0.0)
        runToRest(p)
        XCTAssertEqual(p.balls[1].state, BallState.pocketed, "straight shot did not pot")
        XCTAssertEqual(p.balls[1].pocket, 3)
        XCTAssertGreaterThan(p.balls[1].dropSpeed, 0.5)

        // head-on hit at 1.5 m/s: cue ball 0.3 m from the object ball at x = 0; look at the cue ball 1 s later
        func headOn(_ top: Double) -> Double {
            let q = table([(id: 0, x: -0.3, y: 0.0), (id: 1, x: 0.0, y: 0.0)])
            q.strike(angle: 0.0, speed: 1.5, side: 0.0, top: top)
            for _ in 0..<120 {
                q.step(1.0 / 120.0)
            }
            return q.balls[0].x
        }
        let fx: Double = headOn(0.4)
        let sx: Double = headOn(-0.15)
        let dx: Double = headOn(-0.45)
        XCTAssertGreaterThan(fx, -PoolConst.D + 0.15, "follow shot did not follow")
        XCTAssertLessThan(abs(sx + PoolConst.D), 0.05, "stun shot did not stop at the contact point")
        XCTAssertLessThan(dx, -PoolConst.D - 0.1, "draw shot did not draw back")
    }

    func testCushionRebound() {
        // a rolling ball at 30 degrees into the +y cushion keeps its along-rail speed, angle mirrored
        let q = table([(id: 1, x: 0.0, y: 0.3)])
        let b: Ball = q.balls[1]
        let ang: Double = 30.0 * Double.pi / 180.0
        b.vx = 2.0 * cos(ang)
        b.vy = 2.0 * sin(ang)
        b.wy = b.vx / PoolConst.R
        b.wx = -b.vy / PoolConst.R
        var seen: Bool = false
        var guardSteps: Int = 0
        while !seen && guardSteps < 2000 {
            guardSteps += 1
            q.step(1.0 / 240.0)
            for ev in q.events {
                if case .cushion = ev {
                    seen = true
                }
            }
            q.events.removeAll()
        }
        XCTAssertTrue(seen)
        q.step(1.0 / 240.0)
        let out: Double = atan2(-b.vy, b.vx) * 180.0 / Double.pi
        XCTAssertGreaterThan(out, 20.0)
        XCTAssertLessThan(out, 40.0)
    }

    private func rollInto(_ x: Double, _ y: Double, _ angle: Double, _ speed: Double) -> Int? {
        let q = table([(id: 1, x: x, y: y)])
        let c: Ball = q.balls[1]
        c.vx = speed * cos(angle)
        c.vy = speed * sin(angle)
        c.wy = c.vx / PoolConst.R
        c.wx = -c.vy / PoolConst.R
        runToRest(q, limit: 10.0)
        if c.state == BallState.pocketed {
            return c.pocket
        }
        return nil
    }

    func testPocketsAlwaysDrop() {
        let px: Double = PoolConst.cornerPocket.0
        let py: Double = PoolConst.cornerPocket.1
        XCTAssertEqual(rollInto(0.0, 0.3, Double.pi / 2.0, 2.0), 5)
        XCTAssertEqual(rollInto(0.0, -0.3, -Double.pi / 2.0, 2.0), 4)
        // a ball that reaches a pocket goes in, however fast and at whatever angle it comes into the mouth
        let speeds: [Double] = [0.6, 2.0, 5.0, 9.0]
        let offsets: [Double] = [-1.0, 0.0, 1.0]
        for speed in speeds {
            for s in offsets {
                let ang: Double = (225.0 + s * 12.0) * Double.pi / 180.0
                let x: Double = px + 0.5 * cos(ang)
                let y: Double = py + 0.5 * sin(ang)
                let heading: Double = atan2(py - y, px - x)
                XCTAssertNotNil(rollInto(x, y, heading, speed), "a ball rolled into the mouth must drop (speed \(speed), side \(s))")
            }
        }
    }

    func testBreakStaysPhysical() {
        let p = Physics()
        p.rack(seed: 3)
        p.strike(angle: 0.0, speed: 5.6, side: 0.0, top: 0.0)
        let mass: Double = PoolConst.mass
        let inertia: Double = 0.4 * mass * PoolConst.R * PoolConst.R
        func energy() -> Double {
            var e: Double = 0.0
            for b in p.balls {
                if b.state == BallState.active {
                    e += 0.5 * mass * (b.vx * b.vx + b.vy * b.vy)
                    e += 0.5 * inertia * (b.wx * b.wx + b.wy * b.wy + b.wz * b.wz)
                }
            }
            return e
        }
        var last: Double = energy()
        var worstRise: Double = 0.0
        var t: Double = 0.0
        let dt: Double = 1.0 / 60.0
        while p.moving() && t < 60.0 {
            p.step(dt)
            t += dt
            let e: Double = energy()
            worstRise = max(worstRise, e - last)
            last = e
            for b in p.activeBalls() {
                XCTAssertTrue(b.x.isFinite && b.y.isFinite, "NaN position")
                XCTAssertLessThanOrEqual(abs(b.x), PoolConst.HL)
                XCTAssertLessThanOrEqual(abs(b.y), PoolConst.HW)
            }
            p.events.removeAll()
        }
        XCTAssertLessThan(t, 30.0, "break took too long to settle")
        XCTAssertLessThan(worstRise, 1e-9, "energy increased")
        XCTAssertGreaterThan(minGap(p), PoolConst.D - 5e-4, "balls sank into each other")
    }

    func testDeterminismAndSnapshot() {
        let start = Physics()
        start.rack(seed: 11)
        let snap: BallSnapshot = start.snapshot()
        let r1: ShotOutcome = simulateShot(snap, angle: 0.05, speed: 5.0, side: 0.0, top: 0.0)
        let r2: ShotOutcome = simulateShot(snap, angle: 0.05, speed: 5.0, side: 0.0, top: 0.0)
        XCTAssertEqual(r1.final.count, r2.final.count)
        for i in 0..<min(r1.final.count, r2.final.count) {
            XCTAssertEqual(r1.final[i].id, r2.final[i].id)
            XCTAssertEqual(r1.final[i].x, r2.final[i].x)
            XCTAssertEqual(r1.final[i].y, r2.final[i].y)
        }
        XCTAssertEqual(r1.pocketed, r2.pocketed)
        XCTAssertGreaterThan(r1.time, 0.0)

        // restore brings every ball back
        let p = Physics()
        p.rack(seed: 11)
        p.strike(angle: 0.05, speed: 5.0, side: 0.0, top: 0.0)
        for _ in 0..<200 {
            p.step(1.0 / 120.0)
        }
        p.restore(snap)
        XCTAssertFalse(p.moving())
        for i in 0..<16 {
            XCTAssertEqual(p.balls[i].x, start.balls[i].x)
            XCTAssertEqual(p.balls[i].y, start.balls[i].y)
            XCTAssertEqual(p.balls[i].state, BallState.active)
        }
        XCTAssertEqual(p.activeBalls().count, 16)
    }

    func testShotSimIncremental() {
        let start = Physics()
        start.rack(seed: 5)
        let sim = ShotSim(snapshot: start.snapshot(), angle: 0.0, speed: 6.0, side: 0.0, top: 0.0, maxTime: 20.0, dt: 1.0 / 120.0)
        var calls: Int = 0
        while !sim.advance(3) && calls < 100000 {
            calls += 1
        }
        XCTAssertTrue(sim.done)
        XCTAssertNotNil(sim.firstHit)
        let o: ShotOutcome = sim.outcome
        XCTAssertEqual(o.time, sim.time)
        XCTAssertFalse(o.final.isEmpty)
    }

    func testIsFreeAndPlaceBall() {
        let p = Physics(empty: true)
        for b in p.balls {
            b.state = BallState.pocketed
        }
        p.placeBall(0, x: 0.0, y: 0.0)
        XCTAssertFalse(p.isFree(x: 0.03, y: 0.0))
        XCTAssertTrue(p.isFree(x: 0.03, y: 0.0, radius: PoolConst.R, ignore: 0))
        XCTAssertTrue(p.isFree(x: 0.5, y: 0.2))
        XCTAssertFalse(p.isFree(x: PoolConst.HL, y: 0.0))
        p.balls[0].state = BallState.pocketed
        p.refreshActive()
        XCTAssertTrue(p.activeBalls().isEmpty)
        p.placeBall(0, x: 0.2, y: 0.1)
        XCTAssertEqual(p.activeBalls().count, 1)
        XCTAssertEqual(p.balls[0].state, BallState.active)
    }

    func testStrikeSetsSpinAndEvent() {
        let p = table([(id: 0, x: 0.0, y: 0.0)])
        p.strike(angle: 0.0, speed: 2.0, side: 0.3, top: 0.2)
        XCTAssertGreaterThan(p.balls[0].vx, 0.0)
        XCTAssertEqual(p.balls[0].vy, 0.0, accuracy: 1e-12)
        XCTAssertGreaterThan(p.balls[0].wz, 0.0)
        XCTAssertEqual(p.events.count, 1)
        if case .cueHit(let id, let speed) = p.events[0] {
            XCTAssertEqual(id, 0)
            XCTAssertGreaterThan(speed, 0.0)
        } else {
            XCTFail("strike must queue a cueHit event")
        }
        XCTAssertTrue(p.moving())
    }
}
