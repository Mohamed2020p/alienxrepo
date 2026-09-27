import Foundation
import SceneKit
import UIKit
import simd

/// A man in one outfit: places him in the world, plays and blends the baked clips, and reports where the cue in his hands is.
/// (A port of pg_people.Person.) Positions are game coordinates; heading `h` is in degrees, counter clockwise seen from above,
/// the man faces -Y at heading 0.
@MainActor
final class Person {
    let name: String
    let root: SCNNode = SCNNode()
    private let assets: ManAssets
    private let variant: ManVariant
    private var partNodes: [SCNNode] = []
    private var partMaterials: [SCNMaterial] = []
    private var frameGeometries: [Int: [SCNGeometry]] = [:]

    private(set) var x: Double = 0
    private(set) var y: Double = 0
    private(set) var h: Double = 0

    // the clip player
    private(set) var clipName: String = "Idle"
    private var clipStart: Int = 0
    private var clipFrames: Int = 1
    private(set) var t: Double = 0
    var rate: Double = 24
    private var loop: Bool = true
    private var reverse: Bool = false
    private(set) var done: Bool = false
    private var frozen: Bool = false
    private var weights: [(frame: Int, weight: Double)] = []
    private var blendFrom: [(frame: Int, weight: Double)]?
    private var blendT: Double = 0
    private var blendD: Double = 0
    private var shownKey: [Int] = []
    private var lastStep: Int?
    /// Called when a foot touches the ground during the walk cycle (heel strikes at frames 0 and 12).
    var onStep: (() -> Void)?

    private var extras: [(node: SCNNode, spine: Bool)] = []

    init(assets: ManAssets, variant: ManVariant, name: String, parent: SCNNode) {
        self.assets = assets
        self.variant = variant
        self.name = name
        root.name = name
        parent.addChildNode(root)
        buildParts()
        if variant.accessories {
            buildExtras()
        }
        setClip("Idle", loop: true)
        update(dt: 0)
    }

    // MARK: - look

    private func paletteImage() -> UIImage? {
        let c: [String: SIMD3<Float>] = variant.colors
        let white: SIMD3<Float> = SIMD3<Float>(1, 1, 1)
        let jacket: SIMD3<Float> = c["jacket"] ?? white
        let shirt: SIMD3<Float> = c["shirt"] ?? white
        let list: [SIMD3<Float>] = [jacket, c["sleeve"] ?? jacket, c["pants"] ?? white, c["shoes"] ?? white, shirt, c["cuff"] ?? shirt, c["tie"] ?? white, jacket]
        var pixels: [UInt8] = []
        for col in list {
            pixels.append(UInt8(max(0.0, min(1.0, col.x)) * 255.0))
            pixels.append(UInt8(max(0.0, min(1.0, col.y)) * 255.0))
            pixels.append(UInt8(max(0.0, min(1.0, col.z)) * 255.0))
            pixels.append(255)
        }
        var image: UIImage?
        pixels.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Void in
            let space = CGColorSpaceCreateDeviceRGB()
            let info: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
            if let ctx = CGContext(data: buf.baseAddress, width: 8, height: 1, bitsPerComponent: 8, bytesPerRow: 32, space: space, bitmapInfo: info),
               let cg = ctx.makeImage() {
                image = UIImage(cgImage: cg)
            }
        }
        return image
    }

    private func material(for part: ManAssets.Part) -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = SCNMaterial.LightingModel.blinn
        m.specular.contents = UIColor(white: 0.12, alpha: 1)
        m.shininess = 20
        switch part.role {
        case "skin":
            if let tex = part.texture { m.diffuse.contents = DataStore.image(tex) }
            m.multiply.contents = MeshKit.uiColor(variant.skin)
            m.diffuse.mipFilter = SCNFilterMode.linear
        case "eye", "teeth":
            if let tex = part.texture { m.diffuse.contents = DataStore.image(tex) }
            m.specular.contents = UIColor(white: 0.6, alpha: 1)
            m.shininess = 60
        case "lash":
            m.diffuse.contents = UIColor(red: 0.02, green: 0.015, blue: 0.015, alpha: 1)
        case "hair":
            m.diffuse.contents = DataStore.image("skins/" + variant.hair)
            m.diffuse.mipFilter = SCNFilterMode.linear
        case "print":
            if let design = variant.design {
                m.diffuse.contents = DataStore.image("skins/" + design)
                m.blendMode = SCNBlendMode.alpha
                m.writesToDepthBuffer = false
                m.transparencyMode = SCNTransparencyMode.aOne
            }
        default:
            // "garments": the whole outfit in one draw call, coloured by the person's 8 x 1 palette (nearest filtering: one texel per garment)
            m.diffuse.contents = paletteImage()
            m.diffuse.magnificationFilter = SCNFilterMode.nearest
            m.diffuse.minificationFilter = SCNFilterMode.nearest
            m.diffuse.mipFilter = SCNFilterMode.none
            m.diffuse.wrapS = SCNWrapMode.clamp
            m.diffuse.wrapT = SCNWrapMode.clamp
        }
        return m
    }

    private func buildParts() {
        var i: Int = 0
        while i < assets.parts.count {
            let part: ManAssets.Part = assets.parts[i]
            let m: SCNMaterial = material(for: part)
            partMaterials.append(m)
            let node = SCNNode()
            node.name = part.name
            if part.role == "hair" || part.role == "eye" || part.role == "lash" || part.role == "teeth" || part.role == "print" {
                node.castsShadow = false
            }
            if part.role == "print" {
                node.renderingOrder = 3
                node.isHidden = (variant.design == nil)
            }
            if part.role == "hair" && variant.accessories {
                node.isHidden = true                    // the ninja wears a cloth hood instead
            }
            root.addChildNode(node)
            partNodes.append(node)
            i += 1
        }
    }

    private static let extraLooks: [String: MeshKit.Look] = [
        "Mask": MeshKit.Look(texture: "tex/ninja_cloth.jpg", spec: 0.05, shine: 5),
        "Cloth": MeshKit.Look(texture: "tex/ninja_cloth.jpg", spec: 0.05, shine: 5),
        "Sun": MeshKit.Look(color: SIMD3<Float>(0.85, 0.06, 0.06), spec: 0.3, shine: 20),
        "Sheath": MeshKit.Look(texture: "tex/ninja_sheath.jpg", spec: 0.9, shine: 90),
        "Handle": MeshKit.Look(color: SIMD3<Float>(0.05, 0.05, 0.09), spec: 0.3, shine: 30),
        "Guard": MeshKit.Look(color: SIMD3<Float>(0.85, 0.62, 0.2), spec: 1.0, shine: 80),
        "Cord": MeshKit.Look(color: SIMD3<Float>(0.75, 0.06, 0.06), spec: 0.2, shine: 20)
    ]

    /// The mask, hood and headband follow the head bone, the katana follows the spine (rigid pieces moved by the baked bone matrices).
    private func buildExtras() {
        for (group, spine) in [("head", false), ("back", true)] {
            let holder = SCNNode()
            holder.name = group + "_extras"
            if let parts = assets.extras.groups[group] {
                for (name, part) in parts {
                    let geo: SCNGeometry = MeshKit.soup(positions: part.positions, normals: part.normals, uvs: part.uvs)
                    let look: MeshKit.Look = Person.extraLooks[name] ?? MeshKit.Look(color: SIMD3<Float>(0.5, 0.5, 0.5))
                    geo.materials = [MeshKit.material(look, anisotropy: 4)]
                    let node = SCNNode(geometry: geo)
                    node.name = name
                    holder.addChildNode(node)
                }
            }
            root.addChildNode(holder)
            extras.append((node: holder, spine: spine))
        }
    }

    private func updateExtras() {
        for e in extras {
            var m: [Double] = [Double](repeating: 0, count: 12)
            for w in weights {
                let bm: [Double] = assets.boneMatrix(frame: w.frame, spine: e.spine)
                var i: Int = 0
                while i < 12 {
                    m[i] += bm[i] * w.weight
                    i += 1
                }
            }
            let c0: SIMD4<Float> = SIMD4<Float>(Float(m[0]), Float(m[4]), Float(m[8]), 0)
            let c1: SIMD4<Float> = SIMD4<Float>(Float(m[1]), Float(m[5]), Float(m[9]), 0)
            let c2: SIMD4<Float> = SIMD4<Float>(Float(m[2]), Float(m[6]), Float(m[10]), 0)
            let c3: SIMD4<Float> = SIMD4<Float>(Float(m[3]), Float(m[7]), Float(m[11]), 1)
            e.node.simdTransform = simd_float4x4(columns: (c0, c1, c2, c3))
        }
    }

    // MARK: - placement

    func place(x: Double, y: Double, h: Double? = nil) {
        self.x = x
        self.y = y
        if let hh = h {
            self.h = hh
        }
        root.simdPosition = SIMD3<Float>(Float(x), Float(y), 0)
        root.simdOrientation = SceneMath.yaw(degrees: self.h)
    }

    func turnToward(_ target: Double, maxStep: Double) {
        let d: Double = SceneMath.angleDiff(h, target)
        h += max(-maxStep, min(maxStep, d))
        root.simdOrientation = SceneMath.yaw(degrees: h)
    }

    func setVisible(_ visible: Bool) {
        root.isHidden = !visible
    }

    // MARK: - animation

    func setClip(_ name: String, loop: Bool = false, reverse: Bool = false, rate: Double = 24, blend: Double = 0, start: Double? = nil) {
        let c: ManAssets.Clip = assets.clip(name)
        if blend > 0 && !weights.isEmpty {
            blendFrom = weights
            blendT = 0
            blendD = blend
        } else {
            blendFrom = nil
        }
        clipName = name
        clipStart = c.start
        clipFrames = c.frames
        self.loop = loop
        self.reverse = reverse
        self.rate = rate
        frozen = false
        if let s = start {
            t = s
        } else {
            t = reverse ? Double(c.frames - 1) : 0
        }
        done = c.frames == 1
    }

    /// Show clip `name` at time t (frames) and hold it there.
    func scrub(_ name: String, t newT: Double, blend: Double = 0) {
        if clipName != name {
            setClip(name, blend: blend)
        }
        frozen = true
        t = max(0, min(newT, Double(clipFrames - 1)))
        done = false
    }

    func progress() -> Double {
        if clipFrames > 1 {
            return t / Double(clipFrames - 1)
        }
        return 1.0
    }

    func update(dt: Double) {
        let n: Int = clipFrames
        if n > 1 && !done && !frozen {
            t += dt * rate * (reverse ? -1.0 : 1.0)
            if loop {
                t = t.truncatingRemainder(dividingBy: Double(n))
                if t < 0 { t += Double(n) }
            } else if !reverse && t >= Double(n - 1) {
                t = Double(n - 1)
                done = true
            } else if reverse && t <= 0 {
                t = 0
                done = true
            }
        }
        if clipName == "Walk" && loop, let cb = onStep {
            let step: Int = Int(t / (Double(n) / 2.0))
            if let last = lastStep, last != step {
                cb()
            }
            lastStep = step
        } else {
            lastStep = nil
        }
        let i: Int = Int(t.rounded(.down))
        let frac: Double = t - Double(i)
        var j: Int = min(i + 1, n - 1)
        if loop { j = (i + 1) % n }
        var w: [Int: Double] = [:]
        if j != i && frac > 0.01 {
            w[clipStart + i] = 1.0 - frac
            w[clipStart + j] = (w[clipStart + j] ?? 0) + frac
        } else {
            w[clipStart + i] = 1.0
        }
        if let from = blendFrom {
            blendT += dt
            let k: Double = SceneMath.ease(blendT / max(blendD, 1e-6))
            var mixed: [Int: Double] = [:]
            for (f, ww) in w {
                mixed[f] = ww * k
            }
            for item in from {
                mixed[item.frame] = (mixed[item.frame] ?? 0) + item.weight * (1.0 - k)
            }
            w = mixed
            if blendT >= blendD {
                blendFrom = nil
            }
        }
        apply(w)
    }

    private func apply(_ raw: [Int: Double]) {
        var list: [(frame: Int, weight: Double)] = []
        var total: Double = 0
        for f in raw.keys.sorted() {
            let ww: Double = raw[f] ?? 0
            if ww > 0.004 {
                list.append((frame: f, weight: ww))
                total += ww
            }
        }
        if list.isEmpty || total <= 0 { return }
        var i: Int = 0
        while i < list.count {
            list[i].weight = list[i].weight / total
            i += 1
        }
        weights = list
        if !extras.isEmpty {
            updateExtras()
        }
        var key: [Int] = []
        for item in list {
            key.append(item.frame)
            key.append(Int((item.weight * 100.0).rounded()))
        }
        if key == shownKey { return }
        shownKey = key
        if list.count == 1 || assets.dynamicUsed >= assets.dynamicBudget {
            var best: (frame: Int, weight: Double) = list[0]
            for item in list where item.weight > best.weight {
                best = item
            }
            showStatic(frame: best.frame)
            return
        }
        assets.dynamicUsed += 1
        var mix: [(frame: Int, weight: Float)] = []
        for item in list {
            mix.append((frame: item.frame, weight: Float(item.weight)))
        }
        var p: Int = 0
        while p < partNodes.count {
            let g: SCNGeometry = assets.geometry(part: p, weights: mix)
            g.materials = [partMaterials[p]]
            partNodes[p].geometry = g
            p += 1
        }
    }

    private func showStatic(frame: Int) {
        if let cached = frameGeometries[frame] {
            var p: Int = 0
            while p < partNodes.count {
                partNodes[p].geometry = cached[p]
                p += 1
            }
            return
        }
        var built: [SCNGeometry] = []
        var p: Int = 0
        while p < partNodes.count {
            let g: SCNGeometry = assets.geometry(part: p, weights: [(frame: frame, weight: 1.0)])
            g.materials = [partMaterials[p]]
            built.append(g)
            partNodes[p].geometry = g
            p += 1
        }
        frameGeometries[frame] = built
    }

    // MARK: - the cue in his hands

    /// (tip, direction butt -> tip) of his cue in his own frame, blended like the pose.
    func cueLocal() -> (tip: SIMD3<Double>, dir: SIMD3<Double>) {
        var tip: SIMD3<Double> = SIMD3<Double>(0, 0, 0)
        var dir: SIMD3<Double> = SIMD3<Double>(0, 0, 0)
        for w in weights {
            let a = assets.anchor(frame: w.frame)
            tip += a.tip * w.weight
            dir += a.dir * w.weight
        }
        let len: Double = simd_length(dir)
        if len > 1e-9 {
            dir = dir / len
        } else {
            dir = SIMD3<Double>(0, 0, 1)
        }
        return (tip, dir)
    }

    /// The cue in game coordinates.
    func cueWorld() -> (tip: SIMD3<Double>, dir: SIMD3<Double>) {
        let local = cueLocal()
        let a: Double = SceneMath.radians(h)
        let c: Double = cos(a)
        let s: Double = sin(a)
        let tip: SIMD3<Double> = SIMD3<Double>(local.tip.x * c - local.tip.y * s + x, local.tip.x * s + local.tip.y * c + y, local.tip.z)
        let dir: SIMD3<Double> = SIMD3<Double>(local.dir.x * c - local.dir.y * s, local.dir.x * s + local.dir.y * c, local.dir.z)
        return (tip, dir)
    }
}
