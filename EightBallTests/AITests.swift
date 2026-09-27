import XCTest
@testable import EightBall

/// Every difficulty must return a finite, sane shot within a bounded number of `step` calls, obey the ball-in-hand rules, and be able
/// to play a whole game against itself.
final class AITests: XCTestCase {

    // MARK: helpers

    private struct Planned {
        var shot: AIShot?
        var calls: Int
    }

    private func plan(_ ai: AIPlanner, _ phys: Physics, _ rules: EightBallRules, player: Int, seed: UInt64,
                      budget: Double = 0.02, maxCalls: Int = 50000) -> Planned {
        ai.start(physics: phys, rules: rules, player: player, seed: seed)
        var shot: AIShot? = nil
        var calls: Int = 0
        while shot == nil && calls < maxCalls {
            shot = ai.step(budget: budget)
            calls += 1
        }
        return Planned(shot: shot, calls: calls)
    }

    private func assertSane(_ shot: AIShot, _ label: String) {
        XCTAssertTrue(shot.angle.isFinite, "\(label): angle")
        XCTAssertTrue(shot.speed.isFinite, "\(label): speed")
        XCTAssertTrue(shot.side.isFinite, "\(label): side")
        XCTAssertTrue(shot.top.isFinite, "\(label): top")
        XCTAssertGreaterThan(shot.speed, 0.1, "\(label): speed too low")
        XCTAssertLessThanOrEqual(shot.speed, 12.5, "\(label): speed too high")
        XCTAssertLessThanOrEqual(abs(shot.side), 0.5, "\(label): side")
        XCTAssertLessThanOrEqual(abs(shot.top), 0.5, "\(label): top")
        if let pl = shot.place {
            XCTAssertTrue(pl.x.isFinite && pl.y.isFinite, "\(label): place")
        }
    }

    /// Places the cue ball if asked, plays the shot in the engine, runs the rules over it. Returns the result.
    private func execute(_ phys: Physics, _ rules: EightBallRules, _ shot: AIShot) -> ShotResult {
        if let pl = shot.place {
            XCTAssertTrue(phys.isFree(x: pl.x, y: pl.y, ignore: 0), "AI placed the cue ball on an occupied spot")
            if rules.kitchenOnly || rules.breakShot {
                XCTAssertLessThan(pl.x, PoolConst.headX, "AI placed the cue ball outside the kitchen")
            }
            phys.placeBall(0, x: pl.x, y: pl.y)
        }
        rules.beginShot()
        phys.strike(angle: shot.angle, speed: shot.speed, side: shot.side, top: shot.top)
        var t: Double = 0.0
        while true {
            phys.step(1.0 / 60.0)
            t += 1.0 / 60.0
            for e in phys.events {
                rules.onEvent(e)
            }
            phys.events.removeAll()
            for b in phys.balls {
                if b.state == BallState.active {
                    let sum: Double = b.x + b.y + b.vx + b.vy + b.wx + b.wy + b.wz
                    XCTAssertTrue(sum.isFinite, "NaN in the physics")
                    XCTAssertLessThanOrEqual(abs(b.x), PoolConst.HL, "ball outside the table")
                    XCTAssertLessThanOrEqual(abs(b.y), PoolConst.HW, "ball outside the table")
                }
            }
            if !phys.moving() {
                break
            }
            if t > 90.0 {
                XCTFail("shot never came to rest")
                break
            }
        }
        let res: ShotResult = rules.endShot(physics: phys)
        for r in res.respot {
            phys.placeBall(r.id, x: r.x, y: r.y)
        }
        return res
    }

    /// A table after a few shots played by the medium AI (deterministic).
    private func midGame(seed: UInt64) -> (Physics, EightBallRules) {
        let phys = Physics()
        phys.rack(seed: seed)
        let rules = EightBallRules()
        rules.reset(firstPlayer: 0)
        let ai = AIPlanner(difficulty: Difficulty.medium)
        var shots: Int = 0
        while shots < 6 {
            shots += 1
            let planned: Planned = plan(ai, phys, rules, player: rules.current, seed: seed &* 1000 &+ UInt64(shots))
            guard let shot = planned.shot else {
                XCTFail("AI did not finish")
                break
            }
            let res: ShotResult = execute(phys, rules, shot)
            if res.gameOver {
                break
            }
        }
        return (phys, rules)
    }

    private func playGame(_ names: [Difficulty], seed: UInt64, maxShots: Int) -> (winner: Int?, shots: Int, fouls: Int) {
        let phys = Physics()
        phys.rack(seed: seed)
        let rules = EightBallRules()
        rules.reset(firstPlayer: Int(seed % 2))
        let planners: [AIPlanner] = [AIPlanner(difficulty: names[0]), AIPlanner(difficulty: names[1])]
        var fouls: Int = 0
        var shots: Int = 0
        while shots < maxShots {
            shots += 1
            let pl: AIPlanner = planners[rules.current]
            let planned: Planned = plan(pl, phys, rules, player: rules.current, seed: seed &* 1000 &+ UInt64(shots), budget: 0.05)
            guard let shot = planned.shot else {
                XCTFail("AI did not finish planning shot \(shots)")
                return (winner: nil, shots: shots, fouls: fouls)
            }
            assertSane(shot, "game shot \(shots)")
            let res: ShotResult = execute(phys, rules, shot)
            if res.foul {
                fouls += 1
            }
            if res.gameOver {
                return (winner: res.winner, shots: shots, fouls: fouls)
            }
        }
        return (winner: nil, shots: maxShots, fouls: fouls)
    }

    // MARK: tests

    func testEveryDifficultyBreaks() {
        let all: [Difficulty] = [Difficulty.easy, Difficulty.medium, Difficulty.hard]
        for d in all {
            let phys = Physics()
            phys.rack(seed: 4)
            let rules = EightBallRules()
            rules.reset(firstPlayer: 0)
            let planned: Planned = plan(AIPlanner(difficulty: d), phys, rules, player: 0, seed: 1)
            XCTAssertNotNil(planned.shot, "\(d.title): no break shot")
            if let shot = planned.shot {
                assertSane(shot, "break \(d.title)")
                XCTAssertNil(shot.place, "the break is played from where the cue ball is")
                // it must aim at the rack (to the +x side)
                XCTAssertLessThan(abs(shot.angle), 0.3)
            }
            XCTAssertLessThan(planned.calls, 50, "\(d.title): the break needs no thinking")
        }
    }

    func testEveryDifficultyOnAMidGameTable() {
        let all: [Difficulty] = [Difficulty.easy, Difficulty.medium, Difficulty.hard]
        for d in all {
            for seed in [UInt64(21), UInt64(22)] {
                let mg = midGame(seed: seed)
                let phys: Physics = mg.0
                let rules: EightBallRules = mg.1
                if rules.winner != nil {
                    continue
                }
                let planned: Planned = plan(AIPlanner(difficulty: d), phys, rules, player: rules.current, seed: seed, budget: 0.004,
                                            maxCalls: 100000)
                XCTAssertNotNil(planned.shot, "\(d.title): no shot after \(planned.calls) calls")
                if let shot = planned.shot {
                    assertSane(shot, "\(d.title) seed \(seed)")
                }
            }
        }
    }

    func testResultDoesNotDependOnTheTimeSlice() {
        let all: [Difficulty] = [Difficulty.easy, Difficulty.medium, Difficulty.hard]
        for d in all {
            let mg = midGame(seed: 31)
            let phys: Physics = mg.0
            let rules: EightBallRules = mg.1
            if rules.winner != nil {
                continue
            }
            let slow: Planned = plan(AIPlanner(difficulty: d), phys, rules, player: rules.current, seed: 5, budget: 0.0,
                                     maxCalls: 400000)
            let fast: Planned = plan(AIPlanner(difficulty: d), phys, rules, player: rules.current, seed: 5, budget: 5.0)
            guard let a = slow.shot, let b = fast.shot else {
                XCTFail("\(d.title): planner did not finish")
                continue
            }
            XCTAssertEqual(a.angle, b.angle, accuracy: 1e-12, "\(d.title): angle")
            XCTAssertEqual(a.speed, b.speed, accuracy: 1e-12, "\(d.title): speed")
            XCTAssertEqual(a.top, b.top, accuracy: 1e-12, "\(d.title): top")
            XCTAssertGreaterThanOrEqual(slow.calls, fast.calls)
        }
    }

    func testHardThinksInSlices() {
        let mg = midGame(seed: 41)
        let phys: Physics = mg.0
        let rules: EightBallRules = mg.1
        if rules.winner != nil {
            return
        }
        let ai = AIPlanner(difficulty: Difficulty.hard)
        ai.start(physics: phys, rules: rules, player: rules.current, seed: 9)
        let first: AIShot? = ai.step(budget: 0.0)
        XCTAssertNil(first, "with no time budget the hard AI cannot have finished its replays in one call")
        var shot: AIShot? = first
        var calls: Int = 1
        while shot == nil && calls < 400000 {
            shot = ai.step(budget: 0.0)
            calls += 1
        }
        XCTAssertNotNil(shot)
        // once finished, step keeps returning the same shot
        let again: AIShot? = ai.step(budget: 0.0)
        XCTAssertNotNil(again)
        if let s = shot, let t = again {
            XCTAssertEqual(s.angle, t.angle)
        }
    }

    func testBallInHandBehindTheHeadString() {
        let all: [Difficulty] = [Difficulty.easy, Difficulty.medium, Difficulty.hard]
        for d in all {
            let mg = midGame(seed: 51)
            let phys: Physics = mg.0
            let rules: EightBallRules = mg.1
            if rules.winner != nil {
                continue
            }
            // pretend the last shot was a foul on the break: kitchen only
            phys.balls[0].state = BallState.pocketed
            phys.refreshActive()
            rules.ballInHand = true
            rules.kitchenOnly = true
            let planned: Planned = plan(AIPlanner(difficulty: d), phys, rules, player: rules.current, seed: 3)
            guard let shot = planned.shot else {
                XCTFail("\(d.title): no shot with ball in hand")
                continue
            }
            assertSane(shot, "kitchen \(d.title)")
            guard let pl = shot.place else {
                XCTFail("\(d.title): ball in hand needs a place")
                continue
            }
            XCTAssertLessThan(pl.x, PoolConst.headX)
            XCTAssertTrue(phys.isFree(x: pl.x, y: pl.y, ignore: 0))
        }
    }

    func testBallInHandAnywhere() {
        let all: [Difficulty] = [Difficulty.easy, Difficulty.medium, Difficulty.hard]
        for d in all {
            let mg = midGame(seed: 61)
            let phys: Physics = mg.0
            let rules: EightBallRules = mg.1
            if rules.winner != nil {
                continue
            }
            phys.balls[0].state = BallState.pocketed
            phys.refreshActive()
            rules.ballInHand = true
            rules.kitchenOnly = false
            let planned: Planned = plan(AIPlanner(difficulty: d), phys, rules, player: rules.current, seed: 8)
            guard let shot = planned.shot, let pl = shot.place else {
                XCTFail("\(d.title): no placement")
                continue
            }
            assertSane(shot, "hand \(d.title)")
            XCTAssertTrue(phys.isFree(x: pl.x, y: pl.y, ignore: 0))
            XCTAssertLessThanOrEqual(abs(pl.x), PoolConst.HL - PoolConst.R)
            XCTAssertLessThanOrEqual(abs(pl.y), PoolConst.HW - PoolConst.R)
        }
    }

    func testOnlyTheCueBallLeft() {
        let phys = Physics(empty: true)
        for b in phys.balls {
            b.state = BallState.pocketed
        }
        phys.placeBall(0, x: -0.5, y: 0.1)
        let rules = EightBallRules()
        rules.reset(firstPlayer: 0)
        rules.breakShot = false
        let planned: Planned = plan(AIPlanner(difficulty: Difficulty.hard), phys, rules, player: 0, seed: 2)
        XCTAssertNotNil(planned.shot)
        if let s = planned.shot {
            assertSane(s, "cue ball only")
        }
    }

    func testSnookeredCueBallStillGetsAShot() {
        // the only legal ball (8: the group is cleared) sits right behind two blockers
        let phys = Physics(empty: true)
        for b in phys.balls {
            b.state = BallState.pocketed
        }
        phys.placeBall(0, x: -0.9, y: 0.0)
        phys.placeBall(9, x: -0.6, y: 0.0)
        phys.placeBall(10, x: -0.5, y: 0.0)
        phys.placeBall(8, x: 0.2, y: 0.0)
        let rules = EightBallRules()
        rules.reset(firstPlayer: 0)
        rules.breakShot = false
        rules.groups = ["solid", "stripe"]
        let all: [Difficulty] = [Difficulty.easy, Difficulty.medium, Difficulty.hard]
        for d in all {
            let planned: Planned = plan(AIPlanner(difficulty: d), phys, rules, player: 0, seed: 12)
            XCTAssertNotNil(planned.shot, "\(d.title): snookered")
            if let s = planned.shot {
                assertSane(s, "snooker \(d.title)")
            }
        }
    }

    func testMediumPlaysAWholeGameAgainstItself() {
        let r = playGame([Difficulty.medium, Difficulty.medium], seed: 1, maxShots: 300)
        XCTAssertGreaterThan(r.shots, 2)
        XCTAssertLessThanOrEqual(r.shots, 300)
    }

    func testEasyAgainstHardPlaysAWholeGame() {
        let r = playGame([Difficulty.easy, Difficulty.hard], seed: 2, maxShots: 300)
        XCTAssertGreaterThan(r.shots, 2)
        XCTAssertLessThanOrEqual(r.shots, 300)
    }
}
