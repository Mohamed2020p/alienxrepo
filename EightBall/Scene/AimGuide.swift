import Foundation
import SceneKit
import UIKit
import simd

/// The aiming aid, drawn like the classic online pool games: a thin solid line from the cue ball to the first thing it hits, a ring where the cue
/// ball will be at that moment (the "ghost ball"), the path the object ball takes, a short line for where the cue ball goes afterwards, the bounce
/// off a cushion, and - when the first ball hit is not the player's - the same in red with a bold X on that ball. Every line is a flat ribbon drawn
/// twice (a soft wide glow and a crisp thin core). (A port of pg_aim.py.)
@MainActor
final class AimGuide {
    private let root: SCNNode = SCNNode()
    private var content: SCNNode?
    private var cacheKey: [Double] = []
    /// The id of the wrong ball the aim points at (nil: fine).
    private(set) var wrongBall: Int?

    private struct Stroke {
        var points: [SIMD2<Double>]
        var z: Double
        var widthCore: Double
        var widthGlow: Double
        var alpha: Double
    }

    init(parent: SCNNode) {
        root.name = "aim guide"
        parent.addChildNode(root)
    }

    func hide() {
        content?.removeFromParentNode()
        content = nil
        cacheKey = []
        wrongBall = nil
    }

    /// First contact of the cue ball travelling from `start` along `angle`: distance, what it hits (a ball id, or a cushion axis), and where the cue ball is then.
    private func trace(_ balls: [Ball], start: SIMD2<Double>, angle: Double) -> (t: Double, ball: Int?, end: SIMD2<Double>, cushionAxis: Int?) {
        let dx: Double = cos(angle)
        let dy: Double = sin(angle)
        let r: Double = PoolConst.R
        var bestT: Double = 1e9
        var hitBall: Int?
        var hitAxis: Int?
        for b in balls {
            if b.id == 0 || b.state != BallState.active { continue }
            let sx: Double = b.x - start.x
            let sy: Double = b.y - start.y
            let bb: Double = dx * sx + dy * sy
            if bb <= 0.0 { continue }
            let disc: Double = bb * bb - (sx * sx + sy * sy - 4.0 * r * r)
            if disc < 0.0 { continue }
            let t: Double = bb - disc.squareRoot()
            if t > 0.0 && t < bestT {
                bestT = t
                hitBall = b.id
                hitAxis = nil
            }
        }
        let limits: [(axis: Int, half: Double)] = [(0, PoolConst.HL - r), (1, PoolConst.HW - r)]
        for lim in limits {
            let d: Double = lim.axis == 0 ? dx : dy
            if abs(d) < 1e-9 { continue }
            let s: Double = lim.axis == 0 ? start.x : start.y
            let t: Double = ((d > 0 ? lim.half : -lim.half) - s) / d
            if t > 0.0 && t < bestT {
                bestT = t
                hitBall = nil
                hitAxis = lim.axis
            }
        }
        return (bestT, hitBall, SIMD2<Double>(start.x + dx * bestT, start.y + dy * bestT), hitAxis)
    }

    private func circle(center: SIMD2<Double>, radius: Double, segments: Int) -> [SIMD2<Double>] {
        var pts: [SIMD2<Double>] = []
        var i: Int = 0
        while i <= segments {
            let a: Double = 2.0 * Double.pi * Double(i) / Double(segments)
            pts.append(SIMD2<Double>(center.x + cos(a) * radius, center.y + sin(a) * radius))
            i += 1
        }
        return pts
    }

    /// level: 0 nothing, 1 the line only, 2 + ghost ball and the object ball's path, 3 + the cue ball's path and the bounce.
    /// legal: the balls the player may hit first (nil = no check).
    func update(balls: [Ball], start: SIMD2<Double>, angle: Double, level: Int, legal: Set<Int>?) {
        if level <= 0 {
            hide()
            return
        }
        let hit = trace(balls, start: start, angle: angle)
        var wrong: Int?
        if let id = hit.ball, let l = legal, !l.contains(id) {
            wrong = id
        }
        let key: [Double] = [start.x, start.y, angle, Double(level), Double(wrong ?? -1)]
        var same: Bool = content != nil && cacheKey.count == key.count
        if same {
            var i: Int = 0
            while i < key.count {
                if abs(cacheKey[i] - key[i]) > 1e-4 { same = false }
                i += 1
            }
        }
        if same { return }
        hide()
        cacheKey = key
        wrongBall = wrong

        let r: Double = PoolConst.R
        let dx: Double = cos(angle)
        let dy: Double = sin(angle)
        let z: Double = TableGeometry.clothHeight + 0.0035
        var strokes: [Stroke] = []
        let from: SIMD2<Double> = SIMD2<Double>(start.x + dx * r * 1.15, start.y + dy * r * 1.15)
        var end: SIMD2<Double> = hit.end
        if level == 1 {
            let t: Double = min(hit.t, 0.9)
            end = SIMD2<Double>(start.x + dx * t, start.y + dy * t)
        }
        strokes.append(Stroke(points: [from, end], z: z, widthCore: 0.0040, widthGlow: 0.012, alpha: 0.95))
        if level >= 2 {
            strokes.append(Stroke(points: circle(center: hit.end, radius: r, segments: 40), z: z, widthCore: 0.0040, widthGlow: 0.012, alpha: 0.95))
            if let id = hit.ball {
                let ob: Ball = balls[id]
                var nx: Double = ob.x - hit.end.x
                var ny: Double = ob.y - hit.end.y
                let nl: Double = max((nx * nx + ny * ny).squareRoot(), 1e-9)
                nx /= nl
                ny /= nl
                let a: SIMD2<Double> = SIMD2<Double>(ob.x + nx * r, ob.y + ny * r)
                let b: SIMD2<Double> = SIMD2<Double>(ob.x + nx * (r + 0.40), ob.y + ny * (r + 0.40))
                strokes.append(Stroke(points: [a, b], z: z, widthCore: 0.0036, widthGlow: 0.011, alpha: 0.85))
                if level >= 3 {
                    let dot: Double = dx * nx + dy * ny
                    var tx: Double = dx - dot * nx
                    var ty: Double = dy - dot * ny
                    let tl: Double = (tx * tx + ty * ty).squareRoot()
                    if tl > 1e-3 {
                        tx /= tl
                        ty /= tl
                        let length: Double = 0.10 + 0.20 * tl            // a grazing hit sends the cue ball on, a straight one stops it
                        let c0: SIMD2<Double> = SIMD2<Double>(hit.end.x + tx * r, hit.end.y + ty * r)
                        let c1: SIMD2<Double> = SIMD2<Double>(hit.end.x + tx * (r + length), hit.end.y + ty * (r + length))
                        strokes.append(Stroke(points: [c0, c1], z: z, widthCore: 0.0030, widthGlow: 0.010, alpha: 0.70))
                    }
                }
            } else if level >= 3, let axis = hit.cushionAxis {
                let rx: Double = axis == 0 ? -dx : dx
                let ry: Double = axis == 0 ? dy : -dy
                let c0: SIMD2<Double> = SIMD2<Double>(hit.end.x + rx * r, hit.end.y + ry * r)
                let c1: SIMD2<Double> = SIMD2<Double>(hit.end.x + rx * (r + 0.45), hit.end.y + ry * (r + 0.45))
                strokes.append(Stroke(points: [c0, c1], z: z, widthCore: 0.0030, widthGlow: 0.010, alpha: 0.70))
            }
        }
        if let w = wrong {
            let ob: Ball = balls[w]
            let zx: Double = TableGeometry.clothHeight + 2.0 * r + 0.004
            let half: Double = 0.032
            let c: SIMD2<Double> = SIMD2<Double>(ob.x, ob.y)
            strokes.append(Stroke(points: [SIMD2<Double>(c.x - half, c.y - half), SIMD2<Double>(c.x + half, c.y + half)], z: zx, widthCore: 0.0075, widthGlow: 0.016, alpha: 1.0))
            strokes.append(Stroke(points: [SIMD2<Double>(c.x - half, c.y + half), SIMD2<Double>(c.x + half, c.y - half)], z: zx, widthCore: 0.0075, widthGlow: 0.016, alpha: 1.0))
        }
        let color: UIColor = wrong != nil ? UIColor(red: 1.0, green: 0.25, blue: 0.2, alpha: 1) : UIColor(white: 1.0, alpha: 1)
        let holder = SCNNode()
        for s in strokes {
            holder.addChildNode(node(for: s, color: color, glow: true))
            holder.addChildNode(node(for: s, color: color, glow: false))
        }
        root.addChildNode(holder)
        content = holder
    }

    private func node(for stroke: Stroke, color: UIColor, glow: Bool) -> SCNNode {
        var positions: [Float] = []
        var indices: [UInt32] = []
        MeshKit.appendRibbon(stroke.points, width: glow ? stroke.widthGlow : stroke.widthCore, z: stroke.z, positions: &positions, indices: &indices)
        var normals: [Float] = []
        var i: Int = 0
        while i < positions.count / 3 {
            normals.append(0)
            normals.append(0)
            normals.append(1)
            i += 1
        }
        let geo: SCNGeometry = MeshKit.geometry(positions: positions, normals: normals, uvs: nil, indices: indices)
        let a: CGFloat = CGFloat(glow ? stroke.alpha * 0.18 : stroke.alpha)
        geo.materials = [MeshKit.flatMaterial(color.withAlphaComponent(a))]
        let n = SCNNode(geometry: geo)
        n.castsShadow = false
        n.renderingOrder = glow ? 30 : 31
        return n
    }
}
