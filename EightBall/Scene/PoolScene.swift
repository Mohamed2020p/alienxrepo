import Foundation
import SceneKit
import UIKit
import simd

/// The pool lounge: room, rug, posters, table with its lamp, chalk, cue rack, stools, the 16 balls, the lights and the camera.
/// Everything hangs under `gameRoot`, which is turned so that SceneKit's Y-up world shows the game's Z-up coordinates
/// (positions, orientations and `SceneMath.lookRotation` are all in game coordinates).
@MainActor
final class PoolScene {
    static let roomHalfX: Double = 5.5
    static let roomHalfY: Double = 4.0
    static let roomHeight: Double = 3.2

    let scene: SCNScene = SCNScene()
    let gameRoot: SCNNode = SCNNode()
    let cameraNode: SCNNode = SCNNode()
    private(set) var balls: [BallView] = []
    private(set) var lamp: SCNNode = SCNNode()
    private let settings: GameSettings
    private let models: SoupFile
    private let spotLight: SCNLight = SCNLight()
    private var anisotropy: CGFloat = 8

    /// What each material of the Blender models looks like (the same table as pg_scene.py).
    private static let looks: [String: MeshKit.Look] = [
        "Baize": MeshKit.Look(texture: "tex/cloth.png", spec: 0.0, shine: 5),
        "Cushion": MeshKit.Look(texture: "tex/cloth.png", color: SIMD3<Float>(0.85, 0.9, 0.85), spec: 0.0, shine: 5),
        "Mahogany": MeshKit.Look(texture: "tex/rail_wood.jpg", spec: 0.55, shine: 60, mirrored: true),
        "Apron": MeshKit.Look(texture: "tex/apron_panel.jpg", spec: 0.35, shine: 40, mirrored: true),
        "Brass": MeshKit.Look(color: SIMD3<Float>(0.86, 0.60, 0.22), spec: 1.0, shine: 70),
        "Pearl": MeshKit.Look(color: SIMD3<Float>(0.94, 0.92, 0.85), spec: 0.8, shine: 60),
        "Pocket": MeshKit.Look(color: SIMD3<Float>(0.01, 0.01, 0.01), spec: 0.0, shine: 1),
        "Leather": MeshKit.Look(color: SIMD3<Float>(0.09, 0.04, 0.025), spec: 0.2, shine: 20),
        "GoldInk": MeshKit.Look(color: SIMD3<Float>(0.86, 0.62, 0.22), spec: 0.6, shine: 40),
        "LampShade": MeshKit.Look(color: SIMD3<Float>(0.03, 0.22, 0.10), spec: 0.5, shine: 40),
        "Bulb": MeshKit.Look(color: SIMD3<Float>(1.0, 0.93, 0.78), emissive: true),
        "Tip": MeshKit.Look(color: SIMD3<Float>(0.08, 0.20, 0.50), spec: 0.0, shine: 1),
        "Ferrule": MeshKit.Look(color: SIMD3<Float>(0.93, 0.91, 0.86), spec: 0.4, shine: 30),
        "Shaft": MeshKit.Look(color: SIMD3<Float>(0.87, 0.70, 0.45), spec: 0.5, shine: 50),
        "Forearm": MeshKit.Look(color: SIMD3<Float>(0.55, 0.26, 0.09), spec: 0.5, shine: 50),
        "Wrap": MeshKit.Look(color: SIMD3<Float>(0.02, 0.02, 0.025), spec: 0.1, shine: 10),
        "Butt": MeshKit.Look(color: SIMD3<Float>(0.10, 0.035, 0.02), spec: 0.6, shine: 60),
        "ButtInlay": MeshKit.Look(color: SIMD3<Float>(0.75, 0.10, 0.07), spec: 0.4, shine: 40),
        "Bumper": MeshKit.Look(color: SIMD3<Float>(0.01, 0.01, 0.01), spec: 0.0, shine: 1),
        "Chalk": MeshKit.Look(color: SIMD3<Float>(0.12, 0.40, 0.80), spec: 0.0, shine: 1)
    ]

    init(settings: GameSettings) {
        self.settings = settings
        self.models = SoupFile(bin: "models.bin", json: "models.json")
        gameRoot.simdEulerAngles = SIMD3<Float>(-Float.pi / 2.0, 0, 0)
        scene.rootNode.addChildNode(gameRoot)
        scene.background.contents = UIColor(red: 0.02, green: 0.02, blue: 0.03, alpha: 1)
        buildCamera()
        buildRoom()
        buildTable()
        buildLights()
        let profile: QualityProfile = settings.profile
        var n: Int = 0
        while n < 16 {
            balls.append(BallView(number: n, parent: gameRoot, profile: profile))
            n += 1
        }
        applyQuality()
    }

    // MARK: - quality

    func applyQuality() {
        let profile: QualityProfile = settings.profile
        anisotropy = profile.shadows ? 8 : 4
        spotLight.castsShadow = profile.shadows
        spotLight.shadowMapSize = CGSize(width: profile.shadowMapSize, height: profile.shadowMapSize)
        for b in balls {
            b.setDetail(profile)
        }
    }

    // MARK: - camera

    /// Places the camera (game coordinates), looks at `look`, horizontal field of view in degrees.
    func setCamera(position: SIMD3<Double>, look: SIMD3<Double>, fov: Double) {
        cameraNode.simdPosition = SIMD3<Float>(Float(position.x), Float(position.y), Float(position.z))
        cameraNode.simdOrientation = SceneMath.lookRotation(from: position, to: look)
        cameraNode.camera?.fieldOfView = CGFloat(fov)
    }

    func setLampVisible(_ visible: Bool) {
        lamp.isHidden = !visible
    }

    private func buildCamera() {
        let cam = SCNCamera()
        cam.zNear = 0.05
        cam.zFar = 60
        cam.projectionDirection = SCNCameraProjectionDirection.horizontal
        cam.fieldOfView = 58
        cam.wantsHDR = false
        cameraNode.camera = cam
        cameraNode.simdPosition = SIMD3<Float>(0, -3.6, 2.8)
        gameRoot.addChildNode(cameraNode)
    }

    // MARK: - models from Blender

    /// One child node per material, styled by `looks`; the returned node is a child of `parent`.
    @discardableResult
    func buildModel(_ group: String, into parent: SCNNode) -> SCNNode {
        let holder = SCNNode()
        holder.name = group
        if let parts = models.groups[group] {
            for (name, part) in parts {
                let geo: SCNGeometry = MeshKit.soup(positions: part.positions, normals: part.normals, uvs: part.uvs)
                let look: MeshKit.Look = PoolScene.looks[name] ?? MeshKit.Look(color: SIMD3<Float>(0.5, 0.5, 0.5), spec: 0, shine: 1)
                geo.materials = [MeshKit.material(look, anisotropy: anisotropy)]
                let node = SCNNode(geometry: geo)
                node.name = name
                if look.emissive {
                    node.castsShadow = false
                }
                holder.addChildNode(node)
            }
        }
        parent.addChildNode(holder)
        return holder
    }

    /// A cue with tip at the origin and the butt along -Y; `design` ("you" / "ai") wraps the butt sleeve in that artwork.
    func makeCue(design: String?) -> SCNNode {
        let holder = SCNNode()
        buildModel("cue", into: holder)
        if let d = design, let group = holder.childNode(withName: "cue", recursively: false), let butt = group.childNode(withName: "Butt", recursively: false) {
            let look = MeshKit.Look(texture: "tex/cue_\(d).jpg", spec: 0.7, shine: 70)
            butt.geometry?.materials = [MeshKit.material(look, anisotropy: anisotropy)]
        }
        gameRoot.addChildNode(holder)
        return holder
    }

    // MARK: - the table

    private func buildTable() {
        let table = SCNNode()
        table.name = "table"
        table.simdPosition = SIMD3<Float>(0, 0, Float(TableGeometry.clothHeight))
        gameRoot.addChildNode(table)
        buildModel("table", into: table)

        // the gold medallion (made with Nano Banana) laid on the cloth
        let half: Float = 0.44
        let medallionGeo: SCNGeometry = MeshKit.quad(SIMD3<Float>(-half, -half, 0.0012), SIMD3<Float>(half, -half, 0.0012), SIMD3<Float>(half, half, 0.0012),
                                                   SIMD3<Float>(-half, half, 0.0012), normal: SIMD3<Float>(0, 0, 1))
        medallionGeo.materials = [MeshKit.decalMaterial("tex/emblem.png")]
        let medallion = SCNNode(geometry: medallionGeo)
        medallion.castsShadow = false
        medallion.renderingOrder = 2
        table.addChildNode(medallion)

        lamp = buildModel("lamp", into: table)
        lamp.enumerateChildNodes { (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) -> Void in
            child.castsShadow = false
        }

        let chalk = buildModel("chalk", into: gameRoot)
        chalk.simdPosition = SIMD3<Float>(1.05, 0.82, Float(TableGeometry.clothHeight) + 0.045)
        chalk.simdOrientation = SceneMath.yaw(degrees: 30)
    }

    // MARK: - the room

    private func roomMaterial(texture: String, tint: CGFloat, mirrored: Bool) -> SCNMaterial {
        let look = MeshKit.Look(texture: texture, emissive: true, mirrored: mirrored)
        let m: SCNMaterial = MeshKit.material(look, anisotropy: 4)
        m.multiply.contents = UIColor(white: tint, alpha: 1)
        return m
    }

    private func addRoomQuad(_ name: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, normal: SIMD3<Float>, uvScale: SIMD2<Float>,
                             material: SCNMaterial, parent: SCNNode) {
        let geo: SCNGeometry = MeshKit.quad(a, b, c, d, normal: normal, uvScale: uvScale)
        geo.materials = [material]
        let node = SCNNode(geometry: geo)
        node.name = name
        node.castsShadow = false
        parent.addChildNode(node)
    }

    private func buildRoom() {
        let room = SCNNode()
        room.name = "room"
        gameRoot.addChildNode(room)
        let hx: Float = Float(PoolScene.roomHalfX)
        let hy: Float = Float(PoolScene.roomHalfY)
        let hz: Float = Float(PoolScene.roomHeight)

        let floorLook = MeshKit.Look(texture: "tex/floor.png", spec: 0.35, shine: 40)
        addRoomQuad("floor", SIMD3<Float>(-hx, -hy, 0), SIMD3<Float>(hx, -hy, 0), SIMD3<Float>(hx, hy, 0), SIMD3<Float>(-hx, hy, 0), normal: SIMD3<Float>(0, 0, 1),
                    uvScale: SIMD2<Float>(hx, hy), material: MeshKit.material(floorLook, anisotropy: 8), parent: room)
        let rugLook = MeshKit.Look(texture: "tex/rug.jpg")
        addRoomQuad("rug", SIMD3<Float>(-2.4, -1.6, 0.004), SIMD3<Float>(2.4, -1.6, 0.004), SIMD3<Float>(2.4, 1.6, 0.004), SIMD3<Float>(-2.4, 1.6, 0.004),
                    normal: SIMD3<Float>(0, 0, 1), uvScale: SIMD2<Float>(1, 1), material: MeshKit.material(rugLook, anisotropy: 8), parent: room)
        addRoomQuad("ceiling", SIMD3<Float>(-hx, hy, hz), SIMD3<Float>(hx, hy, hz), SIMD3<Float>(hx, -hy, hz), SIMD3<Float>(-hx, -hy, hz), normal: SIMD3<Float>(0, 0, -1),
                    uvScale: SIMD2<Float>(3, 2), material: roomMaterial(texture: "tex/wall_art.png", tint: 0.3, mirrored: true), parent: room)
        let wallMat: SCNMaterial = roomMaterial(texture: "tex/wall_art.png", tint: 0.72, mirrored: true)
        // -X wall, +X wall, -Y wall, +Y wall; every one seen from inside the room
        addRoomQuad("wall0", SIMD3<Float>(-hx, hy, 0), SIMD3<Float>(-hx, -hy, 0), SIMD3<Float>(-hx, -hy, hz), SIMD3<Float>(-hx, hy, hz), normal: SIMD3<Float>(1, 0, 0),
                    uvScale: SIMD2<Float>(hy * 2 / 3.2, 1), material: wallMat, parent: room)
        addRoomQuad("wall1", SIMD3<Float>(hx, -hy, 0), SIMD3<Float>(hx, hy, 0), SIMD3<Float>(hx, hy, hz), SIMD3<Float>(hx, -hy, hz), normal: SIMD3<Float>(-1, 0, 0),
                    uvScale: SIMD2<Float>(hy * 2 / 3.2, 1), material: wallMat, parent: room)
        addRoomQuad("wall2", SIMD3<Float>(-hx, -hy, 0), SIMD3<Float>(hx, -hy, 0), SIMD3<Float>(hx, -hy, hz), SIMD3<Float>(-hx, -hy, hz), normal: SIMD3<Float>(0, 1, 0),
                    uvScale: SIMD2<Float>(hx * 2 / 3.2, 1), material: wallMat, parent: room)
        addRoomQuad("wall3", SIMD3<Float>(hx, hy, 0), SIMD3<Float>(-hx, hy, 0), SIMD3<Float>(-hx, hy, hz), SIMD3<Float>(hx, hy, hz), normal: SIMD3<Float>(0, -1, 0),
                    uvScale: SIMD2<Float>(hx * 2 / 3.2, 1), material: wallMat, parent: room)

        buildCueRack(in: room, wallY: hy)
        buildStools(in: room)
        buildPosters(in: room, halfX: hx)
    }

    private func buildCueRack(in room: SCNNode, wallY: Float) {
        let rack = SCNNode()
        rack.simdPosition = SIMD3<Float>(-3.6, wallY - 0.05, 0)
        room.addChildNode(rack)
        let woodLook = MeshKit.Look(texture: "tex/wood.png", spec: 0.3, shine: 30)
        addRoomQuad("rack_board", SIMD3<Float>(-0.34, 0, 1.0), SIMD3<Float>(0.34, 0, 1.0), SIMD3<Float>(0.34, 0, 1.55), SIMD3<Float>(-0.34, 0, 1.55),
                    normal: SIMD3<Float>(0, -1, 0), uvScale: SIMD2<Float>(1, 1), material: MeshKit.material(woodLook, anisotropy: 4), parent: rack)
        var k: Int = 0
        while k < 4 {
            let cue = SCNNode()
            buildModel("cue", into: cue)
            cue.simdPosition = SIMD3<Float>(-0.24 + 0.16 * Float(k), -0.03, 1.95)
            cue.simdOrientation = simd_quatf(angle: Float.pi / 2.0, axis: SIMD3<Float>(1, 0, 0))          // tip up, butt down
            cue.enumerateChildNodes { (child: SCNNode, _: UnsafeMutablePointer<ObjCBool>) -> Void in
                child.castsShadow = false
            }
            rack.addChildNode(cue)
            k += 1
        }
    }

    private func cylinderNode(radius: CGFloat, z0: Float, z1: Float, color: UIColor) -> SCNNode {
        let cyl = SCNCylinder(radius: radius, height: CGFloat(z1 - z0))
        let m = SCNMaterial()
        m.lightingModel = SCNMaterial.LightingModel.blinn
        m.diffuse.contents = color
        m.specular.contents = UIColor(white: 0.3, alpha: 1)
        cyl.materials = [m]
        let node = SCNNode(geometry: cyl)
        node.simdEulerAngles = SIMD3<Float>(Float.pi / 2.0, 0, 0)          // the cylinder's axis (Y) becomes the vertical (Z)
        node.simdPosition = SIMD3<Float>(0, 0, (z0 + z1) / 2.0)
        node.castsShadow = false
        return node
    }

    private func buildStools(in room: SCNNode) {
        let gold = UIColor(red: 0.55, green: 0.42, blue: 0.2, alpha: 1)
        let red = UIColor(red: 0.32, green: 0.05, blue: 0.06, alpha: 1)
        let spots: [SIMD2<Float>] = [SIMD2<Float>(-4.6, 3.2), SIMD2<Float>(4.6, -3.2), SIMD2<Float>(4.6, 3.2)]
        for p in spots {
            let stool = SCNNode()
            stool.simdPosition = SIMD3<Float>(p.x, p.y, 0)
            stool.addChildNode(cylinderNode(radius: 0.03, z0: 0.0, z1: 0.66, color: gold))
            stool.addChildNode(cylinderNode(radius: 0.19, z0: 0.66, z1: 0.70, color: red))
            stool.addChildNode(cylinderNode(radius: 0.20, z0: 0.0, z1: 0.02, color: gold))
            room.addChildNode(stool)
        }
    }

    /// Four framed posters (made with Nano Banana) on the side walls.
    private func buildPosters(in room: SCNNode, halfX: Float) {
        let width: Float = 0.9
        let height: Float = 1.2
        let z0: Float = 1.25
        let border: Float = 0.04
        // (file, wall side, y centre): side -1 = the -X wall, +1 = the +X wall
        let posters: [(String, Float, Float)] = [("amsterdam", -1, -1.3), ("marrakech", -1, 1.3), ("delft", 1, -1.3), ("zellige", 1, 1.3)]
        for poster in posters {
            let rel: String = "art/poster_\(poster.0).jpg"
            if !DataStore.exists(rel) { continue }
            let side: Float = poster.1
            let yc: Float = poster.2
            var layer: Int = 0
            while layer < 2 {
                let grow: Float = layer == 0 ? border : 0
                let x: Float = side * (halfX - 0.008 - 0.008 * Float(layer))
                var ya: Float = yc - width / 2 - grow
                var yb: Float = yc + width / 2 + grow
                let za: Float = z0 - grow
                let zb: Float = z0 + height + grow
                if side > 0 {
                    let t: Float = ya
                    ya = yb
                    yb = t
                }
                let m: SCNMaterial
                if layer == 0 {
                    m = MeshKit.flatMaterial(UIColor(red: 0.16, green: 0.09, blue: 0.05, alpha: 1))
                    m.blendMode = SCNBlendMode.replace
                    m.writesToDepthBuffer = true
                } else {
                    m = roomMaterial(texture: rel, tint: 0.9, mirrored: false)
                }
                addRoomQuad("poster", SIMD3<Float>(x, ya, za), SIMD3<Float>(x, yb, za), SIMD3<Float>(x, yb, zb), SIMD3<Float>(x, ya, zb), normal: SIMD3<Float>(-side, 0, 0),
                            uvScale: SIMD2<Float>(1, 1), material: m, parent: room)
                layer += 1
            }
        }
    }

    // MARK: - lights

    private func buildLights() {
        let amb = SCNLight()
        amb.type = SCNLight.LightType.ambient
        amb.color = UIColor(red: 0.42, green: 0.38, blue: 0.35, alpha: 1)
        amb.intensity = 1000
        let ambNode = SCNNode()
        ambNode.light = amb
        gameRoot.addChildNode(ambNode)

        let fill = SCNLight()
        fill.type = SCNLight.LightType.directional
        fill.color = UIColor(red: 0.22, green: 0.24, blue: 0.30, alpha: 1)
        fill.intensity = 1000
        fill.castsShadow = false
        let fillNode = SCNNode()
        fillNode.light = fill
        fillNode.simdOrientation = SceneMath.lookRotation(from: SIMD3<Double>(0, 0, 0), to: SIMD3<Double>(0.5, 0.5, -0.7))
        gameRoot.addChildNode(fillNode)

        // the hanging lamp: a wide spot straight down from the hood, it casts the shadows (its default direction, -Z, is straight down)
        spotLight.type = SCNLight.LightType.spot
        spotLight.color = UIColor(red: 1.0, green: 0.86, blue: 0.69, alpha: 1)
        spotLight.intensity = 1250
        spotLight.spotInnerAngle = 50
        spotLight.spotOuterAngle = 120
        spotLight.zNear = 0.4
        spotLight.zFar = 8
        spotLight.attenuationStartDistance = 2.0
        spotLight.attenuationEndDistance = 7.0
        spotLight.attenuationFalloffExponent = 1.0
        spotLight.shadowColor = UIColor(white: 0, alpha: 0.6)
        spotLight.shadowRadius = 3
        spotLight.shadowSampleCount = 8
        let spotNode = SCNNode()
        spotNode.light = spotLight
        spotNode.simdPosition = SIMD3<Float>(0, 0, Float(TableGeometry.clothHeight) + 1.25)
        gameRoot.addChildNode(spotNode)
    }
}
