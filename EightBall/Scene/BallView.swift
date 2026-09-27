import Foundation
import SceneKit
import UIKit
import simd

/// Table constants shared by the scene code (game coordinates: metres, Z up).
enum TableGeometry {
    static let clothHeight: Double = 0.80
    static let ballRadius: Double = 0.02858
    /// Pocket centres in the order of the physics: corners (-,-) (-,+) (+,-) (+,+), then the two side pockets.
    static let pockets: [(x: Double, y: Double)] = [(-1.302, -0.667), (-1.302, 0.667), (1.302, -0.667), (1.302, 0.667), (0.0, -0.699), (0.0, 0.699)]
    /// Outer half sizes of the table (the apron): people never walk into this rectangle.
    static let outerHalfX: Double = 1.478
    static let outerHalfY: Double = 0.845
}

/// One 3D ball: a textured sphere, a soft contact shadow, and the animation of it dropping into a pocket.
@MainActor
final class BallView {
    let number: Int
    let node: SCNNode
    private let blob: SCNNode
    private var sphereNode: SCNNode
    private var orientation: simd_quatf
    private var profile: QualityProfile

    /// (x, y): show the ball here instead of where the physics has it (ball in hand).
    var forcedPosition: (x: Double, y: Double)?
    /// Called while the ball knocks against the inside of a pocket: x, y, volume.
    var onRattle: ((Double, Double, Double) -> Void)?
    /// Called when the ball has disappeared down the pocket.
    var onDropFinished: ((Int) -> Void)?

    private struct Drop {
        var x: Double
        var y: Double
        var z: Double
        var vx: Double
        var vy: Double
        var vz: Double
        var px: Double
        var py: Double
        var inner: Double
        var bounces: Int
    }
    private var drop: Drop?

    var isDropping: Bool { return drop != nil }

    init(number: Int, parent: SCNNode, profile: QualityProfile) {
        self.number = number
        self.profile = profile
        self.node = SCNNode()
        self.node.name = "ball\(number)"
        self.sphereNode = SCNNode()
        let yaw: Float = Float.random(in: 0...(2 * Float.pi))
        let pitch: Float = Float.random(in: -0.7...0.7)
        let roll: Float = Float.random(in: 0...(2 * Float.pi))
        let qz: simd_quatf = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 0, 1))
        let qy: simd_quatf = simd_quatf(angle: pitch, axis: SIMD3<Float>(0, 1, 0))
        let qx: simd_quatf = simd_quatf(angle: roll, axis: SIMD3<Float>(1, 0, 0))
        self.orientation = simd_normalize(qz * qy * qx)

        let plane = SCNPlane(width: 0.096, height: 0.096)
        plane.materials = [MeshKit.decalMaterial("tex/blob.png", tint: 1, alpha: CGFloat(min(1.0, profile.contactShadowAlpha * 2.0)))]
        self.blob = SCNNode(geometry: plane)
        self.blob.castsShadow = false
        self.blob.renderingOrder = 5

        node.addChildNode(sphereNode)
        parent.addChildNode(node)
        parent.addChildNode(blob)
        setDetail(profile)
    }

    /// (Re)builds the sphere for a quality profile (segment count, reflections, contact shadow strength).
    func setDetail(_ profile: QualityProfile) {
        self.profile = profile
        sphereNode.removeFromParentNode()
        let sphere = SCNSphere(radius: CGFloat(TableGeometry.ballRadius))
        sphere.segmentCount = profile.ballSegments
        sphere.isGeodesic = false
        let m = SCNMaterial()
        m.lightingModel = SCNMaterial.LightingModel.blinn
        m.diffuse.contents = DataStore.image("tex/ball_\(number).jpg")
        m.diffuse.mipFilter = SCNFilterMode.linear
        m.specular.contents = UIColor(white: 0.9, alpha: 1)
        m.shininess = 110
        if profile.reflections, let env = DataStore.image("tex/env.png") {
            m.reflective.contents = env
            m.reflective.intensity = 0.35
        }
        sphere.materials = [m]
        let n = SCNNode(geometry: sphere)
        n.castsShadow = true
        sphereNode = n
        node.addChildNode(n)
        if let plane = blob.geometry as? SCNPlane {
            plane.materials = [MeshKit.decalMaterial("tex/blob.png", tint: 1, alpha: CGFloat(min(1.0, profile.contactShadowAlpha * 2.0)))]
        }
    }

    // MARK: - driven by the physics

    func sync(_ ball: Ball, dt: Double) {
        if drop != nil {
            updateDrop(dt: dt)
            return
        }
        if ball.state != BallState.active && forcedPosition == nil {
            node.isHidden = true
            blob.isHidden = true
            return
        }
        var x: Double = ball.x
        var y: Double = ball.y
        if let o = forcedPosition {
            x = o.x
            y = o.y
        }
        node.isHidden = false
        blob.isHidden = false
        let w: Double = (ball.wx * ball.wx + ball.wy * ball.wy + ball.wz * ball.wz).squareRoot()
        if w > 1e-3 {
            let axis: SIMD3<Float> = SIMD3<Float>(Float(ball.wx / w), Float(ball.wy / w), Float(ball.wz / w))
            let dq: simd_quatf = simd_quatf(angle: Float(w * dt), axis: axis)
            orientation = simd_normalize(dq * orientation)
        }
        let z: Double = TableGeometry.clothHeight + TableGeometry.ballRadius
        node.simdPosition = SIMD3<Float>(Float(x), Float(y), Float(z))
        node.simdOrientation = orientation
        blob.simdPosition = SIMD3<Float>(Float(x), Float(y), Float(TableGeometry.clothHeight + 0.0015))
    }

    func reset() {
        drop = nil
        node.isHidden = false
        blob.isHidden = false
    }

    // MARK: - into the pocket: rolls over the edge, drops, knocks against the pocket wall and is gone

    func startDrop(from ball: Ball, pocket: Int) {
        let p = TableGeometry.pockets[pocket]
        let sp: Double = min(max(ball.dropSpeed, 0.4), 4.0)
        let inner: Double = pocket < 4 ? 0.052 : 0.058
        drop = Drop(x: ball.x, y: ball.y, z: TableGeometry.clothHeight + TableGeometry.ballRadius, vx: ball.dropDirX * sp, vy: ball.dropDirY * sp,
                    vz: 0.0, px: p.x, py: p.y, inner: inner, bounces: 0)
        blob.isHidden = true
    }

    private func updateDrop(dt: Double) {
        guard var d = drop else { return }
        d.vz -= 7.0 * dt
        d.x += d.vx * dt
        d.y += d.vy * dt
        d.z += d.vz * dt
        let rx: Double = d.x - d.px
        let ry: Double = d.y - d.py
        let rr: Double = (rx * rx + ry * ry).squareRoot()
        if rr > d.inner && d.z < TableGeometry.clothHeight {
            let nx: Double = rx / rr
            let ny: Double = ry / rr
            d.x = d.px + nx * d.inner
            d.y = d.py + ny * d.inner
            let vn: Double = d.vx * nx + d.vy * ny
            if vn > 0 {
                d.vx -= 1.6 * vn * nx
                d.vy -= 1.6 * vn * ny
                if d.bounces < 3 && abs(vn) > 0.4 {
                    d.bounces += 1
                    onRattle?(d.x, d.y, min(1.0, 0.3 + abs(vn) * 0.3))
                }
            }
        }
        let damp: Double = 1.0 - min(dt * 2.0, 1.0)
        d.vx *= damp
        d.vy *= damp
        var axis: SIMD3<Float> = SIMD3<Float>(Float(d.vy), Float(-d.vx), 0.3)
        axis = simd_normalize(axis)
        let dq: simd_quatf = simd_quatf(angle: Float(300.0 * dt * Double.pi / 180.0), axis: axis)
        orientation = simd_normalize(dq * orientation)
        node.simdPosition = SIMD3<Float>(Float(d.x), Float(d.y), Float(d.z))
        node.simdOrientation = orientation
        if d.z < TableGeometry.clothHeight - 0.22 {
            node.isHidden = true
            drop = nil
            onDropFinished?(number)
            return
        }
        drop = d
    }
}
