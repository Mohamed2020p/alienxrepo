import XCTest
@testable import EightBall

/// The same cases as `test_rules` in the Python game's tools/test_pool.py, driven with synthetic physics events.
final class RulesTests: XCTestCase {

    // MARK: helpers

    private func hit(_ a: Int, _ b: Int) -> PhysicsEvent {
        return PhysicsEvent.ballBall(a: a, b: b, speed: 1.0)
    }

    private func rail(_ i: Int) -> PhysicsEvent {
        return PhysicsEvent.cushion(id: i, speed: 1.0)
    }

    private func pot(_ i: Int) -> PhysicsEvent {
        return PhysicsEvent.pocket(id: i, pocket: 3, speed: 1.0)
    }

    /// Feed synthetic events and pocket the listed balls in `phys`, return the ShotResult.
    private func runShot(_ rules: EightBallRules, _ phys: Physics, _ events: [PhysicsEvent], _ pocketed: [Int] = []) -> ShotResult {
        rules.beginShot()
        for i in pocketed {
            phys.balls[i].state = BallState.pocketed
        }
        phys.refreshActive()
        for e in events {
            rules.onEvent(e)
        }
        return rules.endShot(physics: phys)
    }

    private func openTableRules(_ player: Int = 0) -> EightBallRules {
        let r = EightBallRules()
        r.reset(firstPlayer: player)
        r.breakShot = false
        return r
    }

    /// Physics with only the listed (id, x, y) balls on the cloth.
    private func emptyTable(_ placements: [(Int, Double, Double)]) -> Physics {
        let p = Physics()
        for b in p.balls {
            b.state = BallState.pocketed
        }
        for pl in placements {
            p.placeBall(pl.0, x: pl.1, y: pl.2)
        }
        return p
    }

    /// A full table with every ball of `group` ("solid" / "stripe") already off the cloth.
    private func clearedTable(_ group: String) -> Physics {
        let q = Physics()
        let ids: [Int] = (group == "solid") ? Array(1...7) : Array(9...15)
        for i in ids {
            q.balls[i].state = BallState.pocketed
        }
        q.refreshActive()
        return q
    }

    private func setGroups(_ r: EightBallRules) {
        r.groups = ["solid", "stripe"]
    }

    // MARK: tests

    func testInitialState() {
        let r = EightBallRules()
        XCTAssertEqual(r.current, 0)
        XCTAssertEqual(r.groups.count, 2)
        XCTAssertNil(r.groups[0])
        XCTAssertNil(r.groups[1])
        XCTAssertTrue(r.breakShot)
        XCTAssertFalse(r.ballInHand)
        XCTAssertFalse(r.kitchenOnly)
        XCTAssertNil(r.winner)
        XCTAssertEqual(r.message, "Player 1 to break.")
        r.reset(firstPlayer: 1)
        XCTAssertEqual(r.current, 1)
        XCTAssertEqual(r.message, "Player 2 to break.")
    }

    func testScratch() {
        let r = openTableRules()
        let p = Physics()
        let res = runShot(r, p, [hit(0, 3), pot(0)], [0])
        XCTAssertTrue(res.foul)
        XCTAssertTrue(res.reason.contains("scratch"))
        XCTAssertTrue(res.ballInHand)
        XCTAssertEqual(res.nextPlayer, 1)
        XCTAssertFalse(r.kitchenOnly)
    }

    func testWrongBallAndOwnBall() {
        let r = openTableRules()
        let p = Physics()
        setGroups(r)
        var res = runShot(r, p, [hit(0, 9), rail(9)])
        XCTAssertTrue(res.foul)
        XCTAssertEqual(res.reason, "wrong ball first")
        XCTAssertEqual(res.nextPlayer, 1)
        XCTAssertTrue(res.ballInHand)

        r.current = 0
        res = runShot(r, p, [hit(0, 3), rail(3)])
        XCTAssertFalse(res.foul)
        XCTAssertEqual(res.nextPlayer, 1)
        XCTAssertFalse(res.ballInHand)

        r.current = 0
        res = runShot(r, p, [hit(0, 3), pot(3)], [3])
        XCTAssertFalse(res.foul)
        XCTAssertEqual(res.nextPlayer, 0, "pocketing own ball must continue")

        r.current = 0
        res = runShot(r, p, [hit(0, 4), pot(10)], [10])
        XCTAssertEqual(res.nextPlayer, 1, "pocketing an opponent ball ends the turn")
        XCTAssertFalse(res.foul)

        r.current = 0
        res = runShot(r, p, [hit(0, 4)])
        XCTAssertTrue(res.foul)
        XCTAssertEqual(res.reason, "no rail")

        r.current = 0
        res = runShot(r, p, [])
        XCTAssertTrue(res.foul)
        XCTAssertTrue(res.reason.contains("no ball hit"))
    }

    func testGroupAssignmentOnOpenTable() {
        var r = openTableRules()
        var p = Physics()
        var res = runShot(r, p, [hit(0, 3), pot(12)], [12])
        XCTAssertTrue(res.groupsAssigned)
        XCTAssertEqual(r.groups[0], "stripe")
        XCTAssertEqual(r.groups[1], "solid")
        XCTAssertEqual(res.nextPlayer, 0)
        XCTAssertTrue(r.message.contains("stripes"))

        // foul shots do not assign groups
        r = openTableRules()
        p = Physics()
        res = runShot(r, p, [hit(0, 3), pot(5), pot(0)], [5, 0])
        XCTAssertTrue(res.foul)
        XCTAssertFalse(res.groupsAssigned)
        XCTAssertNil(r.groups[0])
        XCTAssertNil(r.groups[1])

        // hitting the 8 first on an open table is a foul
        r = openTableRules()
        p = Physics()
        res = runShot(r, p, [hit(0, 8), rail(8)])
        XCTAssertTrue(res.foul)
        XCTAssertEqual(res.reason, "wrong ball first")
    }

    func testBreakShots() {
        // no groups assigned even when a ball drops
        var r = EightBallRules()
        var p = Physics()
        var res = runShot(r, p, [hit(0, 1), pot(5)], [5])
        XCTAssertFalse(res.foul)
        XCTAssertNil(r.groups[0])
        XCTAssertNil(r.groups[1])
        XCTAssertEqual(res.nextPlayer, 0)
        XCTAssertFalse(r.breakShot)

        // bad break
        r = EightBallRules()
        p = Physics()
        res = runShot(r, p, [hit(0, 1), rail(2), rail(3)])
        XCTAssertTrue(res.foul)
        XCTAssertTrue(res.reason.contains("bad break"))
        XCTAssertTrue(res.ballInHand)
        XCTAssertTrue(r.kitchenOnly)
        XCTAssertEqual(res.nextPlayer, 1)

        // four balls to a rail is a legal break
        r = EightBallRules()
        p = Physics()
        res = runShot(r, p, [hit(0, 1), rail(2), rail(3), rail(4), rail(5)])
        XCTAssertFalse(res.foul)
        XCTAssertEqual(res.nextPlayer, 1)

        // 8 on the break: respotted on the foot spot, no win or loss
        r = EightBallRules()
        p = emptyTable([(0, PoolConst.headX, 0.0), (8, 0.3, 0.3)])
        res = runShot(r, p, [hit(0, 1), pot(8)], [8])
        XCTAssertFalse(res.foul)
        XCTAssertFalse(res.gameOver)
        XCTAssertEqual(res.nextPlayer, 0)
        XCTAssertEqual(res.respot.count, 1)
        if let spot = res.respot.first {
            XCTAssertEqual(spot.id, 8)
            XCTAssertEqual(spot.x, PoolConst.footX, accuracy: 1e-9)
            XCTAssertEqual(spot.y, 0.0, accuracy: 1e-9)
        }

        r = EightBallRules()
        p = Physics()
        res = runShot(r, p, [hit(0, 1), pot(8)], [8])
        if let spot = res.respot.first {
            XCTAssertTrue(p.isFree(x: spot.x, y: spot.y), "respot spot must be free")
        } else {
            XCTFail("the 8 must be respotted")
        }
    }

    func testEightBallWinAndLoss() {
        // legal win
        var r = openTableRules()
        var p = clearedTable("solid")
        setGroups(r)
        var res = runShot(r, p, [hit(0, 8), pot(8)], [8])
        XCTAssertTrue(res.gameOver)
        XCTAssertEqual(res.winner, 0)
        XCTAssertEqual(r.winner, 0)
        XCTAssertFalse(res.foul)

        // 8 with a scratch loses
        r = openTableRules()
        p = clearedTable("solid")
        setGroups(r)
        res = runShot(r, p, [hit(0, 8), pot(8), pot(0)], [8, 0])
        XCTAssertTrue(res.gameOver)
        XCTAssertEqual(res.winner, 1)

        // early 8 loses
        r = openTableRules()
        p = Physics()
        setGroups(r)
        res = runShot(r, p, [hit(0, 3), pot(8)], [8])
        XCTAssertTrue(res.gameOver)
        XCTAssertEqual(res.winner, 1)

        // 8 after a foul (wrong ball first) loses
        r = openTableRules()
        p = clearedTable("solid")
        setGroups(r)
        res = runShot(r, p, [hit(0, 12), pot(8)], [8])
        XCTAssertTrue(res.gameOver)
        XCTAssertEqual(res.winner, 1)

        // last group ball and the 8 in the same shot: the 8 was not yet a legal target -> loss
        r = openTableRules()
        p = clearedTable("solid")
        p.balls[3].state = BallState.active
        p.refreshActive()
        setGroups(r)
        res = runShot(r, p, [hit(0, 3), pot(3), pot(8)], [3, 8])
        XCTAssertTrue(res.gameOver)
        XCTAssertEqual(res.winner, 1)
    }

    func testLegalTargets() {
        let r = openTableRules()
        let p = clearedTable("solid")
        setGroups(r)
        XCTAssertEqual(r.legalTargets(player: 0, physics: p), Set<Int>([8]))
        XCTAssertEqual(r.legalTargets(player: 1, physics: p), Set<Int>(9...15))

        let open = EightBallRules()
        let full = Physics()
        let all: Set<Int> = open.legalTargets(player: 0, physics: full)
        XCTAssertEqual(all.count, 14)
        XCTAssertFalse(all.contains(0))
        XCTAssertFalse(all.contains(8))
    }

    func testTurnFlowThroughRealPhysics() {
        // a real break with the engine: the rules must stay consistent and never crash
        let phys = Physics()
        phys.rack(seed: 7)
        let rules = EightBallRules()
        rules.reset(firstPlayer: 0)
        rules.beginShot()
        phys.strike(angle: 0.0, speed: 7.0, side: 0.0, top: 0.0)
        var guardSteps: Int = 0
        while guardSteps < 20000 {
            guardSteps += 1
            phys.step(1.0 / 120.0)
            for e in phys.events {
                rules.onEvent(e)
            }
            phys.events.removeAll()
            if !phys.moving() {
                break
            }
        }
        XCTAssertFalse(phys.moving())
        let res = rules.endShot(physics: phys)
        XCTAssertTrue(res.nextPlayer == 0 || res.nextPlayer == 1)
        XCTAssertFalse(rules.breakShot)
        XCTAssertFalse(res.gameOver)
        XCTAssertFalse(rules.message.isEmpty)
    }
}
