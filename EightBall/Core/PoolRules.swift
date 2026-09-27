import Foundation

// WPA-style 8-ball rules (slightly simplified), independent of any renderer: a port of pg_rules.py.
//
// Usage per shot:  rules.beginShot(); physics.strike(...); then every physics event goes through rules.onEvent(e) until
// physics.moving() is false; finally rules.endShot(physics:) returns a ShotResult and updates the rules state (current player,
// groups, ball in hand, winner, message).
//
// Simplifications: no called pockets, no re-rack after a bad break (the opponent simply gets ball in hand behind the head string,
// `kitchenOnly`), fouls always give ball in hand, only the 8-ball is ever respotted (when pocketed on the break).

struct ShotResult {
    var foul: Bool = false
    var reason: String = ""
    var pocketed: [Int] = []                   // ids pocketed this shot, in order (cue ball = 0 included)
    var nextPlayer: Int = 0
    var ballInHand: Bool = false
    var respot: [(id: Int, x: Double, y: Double)] = []      // balls to put back with physics.placeBall
    var gameOver: Bool = false
    var winner: Int? = nil
    var groupsAssigned: Bool = false
}

final class EightBallRules {
    var current: Int = 0
    var groups: [String?] = [nil, nil]         // index = player 0/1: "solid", "stripe" or nil (open table)
    var breakShot: Bool = true
    var ballInHand: Bool = false
    var kitchenOnly: Bool = false              // ball in hand must be placed behind the head string
    var winner: Int? = nil
    var message: String = ""

    private var firstHit: Int? = nil
    private var contact: Bool = false
    private var railAfterContact: Bool = false
    private var railBalls: Set<Int> = []
    private var pocketedIds: [Int] = []

    init() {
        reset(firstPlayer: 0)
    }

    func reset(firstPlayer: Int = 0) {
        current = firstPlayer
        groups = [nil, nil]
        breakShot = true
        ballInHand = false                     // the cue ball starts on the head spot
        kitchenOnly = false
        winner = nil
        message = "Player \(firstPlayer + 1) to break."
        beginShot()
    }

    // MARK: queries

    private static func groupIds(_ group: String) -> Set<Int> {
        if group == "solid" {
            return Set<Int>([1, 2, 3, 4, 5, 6, 7])
        }
        return Set<Int>([9, 10, 11, 12, 13, 14, 15])
    }

    private static func groupName(_ group: String) -> String {
        if group == "solid" {
            return "solids"
        }
        return "stripes"
    }

    private static func isSolid(_ id: Int) -> Bool {
        return id >= 1 && id <= 7
    }

    /// Ball ids `player` may hit first, given the balls currently on the table.
    func legalTargets(player: Int, physics: Physics) -> Set<Int> {
        var onTable: Set<Int> = []
        for b in physics.activeBalls() {
            onTable.insert(b.id)
        }
        return targetSet(player, onTable)
    }

    private func targetSet(_ player: Int, _ onTable: Set<Int>) -> Set<Int> {
        if let group = groups[player] {
            let mine: Set<Int> = EightBallRules.groupIds(group).intersection(onTable)
            if !mine.isEmpty {
                return mine
            }
            let eight: Set<Int> = Set<Int>([8])
            return eight.intersection(onTable)
        }
        var out: Set<Int> = []
        for i in onTable {
            if i != 0 && i != 8 {
                out.insert(i)
            }
        }
        return out
    }

    // MARK: shot flow

    func beginShot() {
        firstHit = nil
        contact = false
        railAfterContact = false
        railBalls = []
        pocketedIds = []
    }

    func onEvent(_ e: PhysicsEvent) {
        switch e {
        case .ballBall(let a, let b, _):
            if firstHit == nil && (a == 0 || b == 0) {
                firstHit = (a == 0) ? b : a
                contact = true
            }
        case .cushion(let id, _):
            if id != 0 {
                railBalls.insert(id)
            }
            if contact {
                railAfterContact = true
            }
        case .pocket(let id, _, _):
            pocketedIds.append(id)
        case .cueHit:
            break
        }
    }

    func endShot(physics: Physics) -> ShotResult {
        let p: Int = current
        let opp: Int = 1 - p
        var res = ShotResult()
        res.pocketed = pocketedIds
        let scratch: Bool = pocketedIds.contains(0)
        var objs: [Int] = []
        for i in pocketedIds {
            if i != 0 {
                objs.append(i)
            }
        }
        var onBefore: Set<Int> = []
        for b in physics.activeBalls() {
            onBefore.insert(b.id)
        }
        for i in objs {
            onBefore.insert(i)
        }
        let wasBreak: Bool = breakShot

        var fouls: [String] = []
        if scratch {
            fouls.append("scratch")
        }
        if wasBreak {
            if firstHit == nil {
                fouls.append("no ball hit")
            }
            if objs.isEmpty && railBalls.count < 4 {
                fouls.append("bad break")
            }
        } else {
            let targets: Set<Int> = targetSet(p, onBefore)
            if let fh = firstHit {
                if !targets.contains(fh) {
                    fouls.append("wrong ball first")
                }
            } else {
                fouls.append("no ball hit")
            }
            if contact && objs.isEmpty && !railAfterContact {
                fouls.append("no rail")
            }
        }
        let foul: Bool = !fouls.isEmpty
        res.foul = foul
        res.reason = fouls.joined(separator: ", ")
        var parts: [String] = []

        if objs.contains(8) && wasBreak {
            res.respot.append(EightBallRules.respotEight(physics))
            parts.append("8-ball respotted")
        } else if objs.contains(8) {
            var cleared: Bool = false
            if let group = groups[p] {
                cleared = EightBallRules.groupIds(group).isDisjoint(with: onBefore)
            }
            res.gameOver = true
            if foul || !cleared {
                res.winner = opp
                let how: String = foul ? "with a foul" : "too early"
                parts.append("Player \(p + 1) pocketed the 8-ball \(how)")
            } else {
                res.winner = p
                parts.append("Player \(p + 1) pocketed the 8-ball")
            }
        }

        if !res.gameOver && !wasBreak && !foul && groups[p] == nil {
            var first: Int? = nil
            for i in objs {
                if i != 8 {
                    first = i
                    break
                }
            }
            if let f = first {
                let group: String = EightBallRules.isSolid(f) ? "solid" : "stripe"
                groups[p] = group
                groups[opp] = (group == "solid") ? "stripe" : "solid"
                res.groupsAssigned = true
                parts.insert("Player \(p + 1): \(EightBallRules.groupName(group))", at: 0)
            }
        }

        if foul {
            parts.append("Foul: \(res.reason)")
        } else if !objs.isEmpty && !res.gameOver {
            var names: [String] = []
            for i in objs {
                names.append(String(i))
            }
            parts.append("Pocketed \(names.joined(separator: ", "))")
        }

        if res.gameOver {
            res.nextPlayer = p
            winner = res.winner
            var w: Int = 0
            if let ww = res.winner {
                w = ww
            }
            parts.append("Player \(w + 1) wins")
        } else if foul {
            res.nextPlayer = opp
            res.ballInHand = true
        } else {
            var keeps: Bool = false
            if let group = groups[p], !wasBreak {
                let ids: Set<Int> = EightBallRules.groupIds(group)
                for i in objs {
                    if ids.contains(i) {
                        keeps = true
                    }
                }
            } else {
                keeps = !objs.isEmpty
            }
            res.nextPlayer = keeps ? p : opp
        }

        kitchenOnly = foul && wasBreak
        ballInHand = res.ballInHand
        breakShot = false
        current = res.nextPlayer
        res.winner = winner
        if parts.isEmpty {
            message = "Player \(current + 1) to shoot."
        } else {
            message = parts.joined(separator: ". ") + "."
        }
        beginShot()
        return res
    }

    /// Foot spot, or the nearest free spot along the long axis if it is occupied.
    static func respotEight(_ physics: Physics) -> (id: Int, x: Double, y: Double) {
        let signs: [Int] = [1, -1]
        for k in 0..<40 {
            for sign in signs {
                let x: Double = PoolConst.footX + Double(sign * k) * 0.03
                if physics.isFree(x: x, y: 0.0, ignore: 8) {
                    return (id: 8, x: x, y: 0.0)
                }
            }
        }
        return (id: 8, x: PoolConst.footX, y: 0.0)
    }
}
