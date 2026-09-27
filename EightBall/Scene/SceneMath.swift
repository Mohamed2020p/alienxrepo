import Foundation
import simd

/// Small maths helpers for the scene code. Game coordinates: X long side, Y short side, Z up.
enum SceneMath {
    /// Orientation of a node (camera or light) whose -Z axis points from `from` to `to` and whose +Y axis is as close to `up` as possible.
    static func lookRotation(from: SIMD3<Double>, to: SIMD3<Double>, up: SIMD3<Double> = SIMD3<Double>(0, 0, 1)) -> simd_quatf {
        var f: SIMD3<Double> = to - from
        let flen: Double = simd_length(f)
        if flen < 1e-9 {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
        }
        f = f / flen
        var r: SIMD3<Double> = simd_cross(f, up)
        if simd_length(r) < 1e-6 {
            r = simd_cross(f, SIMD3<Double>(0, 1, 0))
        }
        r = simd_normalize(r)
        let u: SIMD3<Double> = simd_cross(r, f)
        let m = simd_float3x3(columns: (SIMD3<Float>(Float(r.x), Float(r.y), Float(r.z)),
                                        SIMD3<Float>(Float(u.x), Float(u.y), Float(u.z)),
                                        SIMD3<Float>(Float(-f.x), Float(-f.y), Float(-f.z))))
        return simd_quatf(m)
    }

    /// Rotation about the vertical (Z) axis, counter clockwise seen from above.
    static func yaw(degrees: Double) -> simd_quatf {
        return simd_quatf(angle: Float(degrees * Double.pi / 180.0), axis: SIMD3<Float>(0, 0, 1))
    }

    static func radians(_ degrees: Double) -> Double {
        return degrees * Double.pi / 180.0
    }

    static func degrees(_ radians: Double) -> Double {
        return radians * 180.0 / Double.pi
    }

    /// Difference b - a wrapped to -180 ... 180 degrees.
    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d: Double = (b - a).truncatingRemainder(dividingBy: 360.0)
        if d > 180.0 { d -= 360.0 }
        if d < -180.0 { d += 360.0 }
        return d
    }

    static func ease(_ t: Double) -> Double {
        let x: Double = min(max(t, 0.0), 1.0)
        return x * x * (3.0 - 2.0 * x)
    }

    /// Orientation of a node whose +Y axis points along `dir` (the cue: tip forward, butt behind) and whose +Z axis is as close to `up` as possible.
    static func forwardYRotation(dir: SIMD3<Double>, up: SIMD3<Double> = SIMD3<Double>(0, 0, 1)) -> simd_quatf {
        let len: Double = simd_length(dir)
        if len < 1e-9 {
            return simd_quatf(angle: 0, axis: SIMD3<Float>(0, 0, 1))
        }
        let f: SIMD3<Double> = dir / len
        var right: SIMD3<Double> = simd_cross(f, up)
        if simd_length(right) < 1e-6 {
            right = simd_cross(f, SIMD3<Double>(0, 1, 0))
        }
        right = simd_normalize(right)
        let z: SIMD3<Double> = simd_cross(right, f)
        let m = simd_float3x3(columns: (SIMD3<Float>(Float(right.x), Float(right.y), Float(right.z)),
                                        SIMD3<Float>(Float(f.x), Float(f.y), Float(f.z)),
                                        SIMD3<Float>(Float(z.x), Float(z.y), Float(z.z))))
        return simd_quatf(m)
    }
}
