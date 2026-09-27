import Foundation
import SceneKit
import UIKit
import simd

/// One outfit of the man (an entry of skins/variants.json).
struct ManVariant {
    let name: String
    let colors: [String: SIMD3<Float>]     // jacket, pants, shoes, shirt, tie (+ sleeve, cuff when they exist)
    let design: String?                    // chest print, a path inside Data/skins
    let hair: String                       // hair texture, a path inside Data/skins
    let skin: SIMD3<Float>                 // skin tone multiplier
    let accessories: Bool                  // the white ninja's mask, hood and sword

    static func vec(_ any: Any?) -> SIMD3<Float>? {
        guard let arr = any as? [Double], arr.count >= 3 else { return nil }
        return SIMD3<Float>(Float(arr[0]), Float(arr[1]), Float(arr[2]))
    }

    static func load() -> [String: ManVariant] {
        var out: [String: ManVariant] = [:]
        guard let root = DataStore.json("skins/variants.json") as? [String: Any], let list = root["variants"] as? [[String: Any]] else { return out }
        for v in list {
            guard let name = v["name"] as? String else { continue }
            var colors: [String: SIMD3<Float>] = [:]
            if let c = v["colors"] as? [String: Any] {
                for (key, value) in c {
                    if let color = vec(value) {
                        colors[key] = color
                    }
                }
            }
            let skin: SIMD3<Float> = vec(v["skin"]) ?? SIMD3<Float>(1, 1, 1)
            let hair: String = (v["hair"] as? String) ?? "hair_black.jpg"
            let design: String? = v["design"] as? String
            let acc: Bool = (v["accessories"] as? Bool) ?? false
            out[name] = ManVariant(name: name, colors: colors, design: design, hair: hair, skin: skin, accessories: acc)
        }
        return out
    }
}

/// All animation frames of the man (int16 positions, int8 normals of every baked frame), the drawable parts, the clip table and the per-frame
/// anchors: where the cue is in his hands and how his head and spine move (the ninja's extras follow those).
@MainActor
final class ManAssets {
    struct Part {
        let name: String
        let role: String
        let texture: String?
        let vertexOffset: Int
        let vertexCount: Int
        let uvByteOffset: Int
        let indexByteOffset: Int
        let indexCount: Int
    }

    struct Clip {
        let name: String
        let start: Int
        let frames: Int
    }

    let parts: [Part]
    let clips: [String: Clip]
    let variants: [String: ManVariant]
    let extras: SoupFile
    let strokeRest: Double
    let maxPull: Double
    let follow: Double
    let walkSpeed: Double
    let frameCount: Int
    let vertexTotal: Int
    private let quant: Float
    private let bin: Data
    private let posBase: Int
    private let nrmBase: Int
    private let uvBase: Int
    private let indexBase: Int
    /// per global frame: cue tip (x, y, z) and direction (x, y, z) in the character's own frame
    private var anchorTip: [SIMD3<Double>] = []
    private var anchorDir: [SIMD3<Double>] = []
    private var headMatrices: [[Double]] = []
    private var spineMatrices: [[Double]] = []
    private var uvSources: [SCNGeometrySource] = []
    private var elements: [SCNGeometryElement] = []
    private var staticSources: [Int: [SCNGeometrySource]] = [:]

    /// How many people may get smooth in-between poses this frame (reset to 0 by the game every frame); set from the quality preset.
    var dynamicBudget: Int = 2
    var dynamicUsed: Int = 0

    init?() {
        guard let meta = DataStore.json("man.json") as? [String: Any], let data = DataStore.data("man.bin") else { return nil }
        guard let quantValue = meta["quant"] as? Double, let frames = meta["frames"] as? Int, let verts = meta["vertices"] as? Int,
              let partList = meta["parts"] as? [[String: Any]], let animList = meta["animations"] as? [[String: Any]] else { return nil }
        self.bin = data
        self.quant = Float(1.0 / quantValue)
        self.frameCount = frames
        self.vertexTotal = verts
        self.posBase = (meta["posByteOffset"] as? Int) ?? 0
        self.nrmBase = (meta["nrmByteOffset"] as? Int) ?? 0
        self.uvBase = (meta["uvByteOffset"] as? Int) ?? 0
        self.indexBase = (meta["indexByteOffset"] as? Int) ?? 0
        self.strokeRest = (meta["strokeRest"] as? Double) ?? 4.0
        self.maxPull = (meta["maxPull"] as? Double) ?? 0.3
        self.follow = (meta["follow"] as? Double) ?? 0.09
        self.walkSpeed = (meta["walkSpeed"] as? Double) ?? 1.31
        var parsedParts: [Part] = []
        for p in partList {
            let part = Part(name: (p["name"] as? String) ?? "", role: (p["role"] as? String) ?? "", texture: p["texture"] as? String,
                            vertexOffset: (p["vertexOffset"] as? Int) ?? 0, vertexCount: (p["vertexCount"] as? Int) ?? 0,
                            uvByteOffset: (p["uvByteOffset"] as? Int) ?? 0, indexByteOffset: (p["indexByteOffset"] as? Int) ?? 0,
                            indexCount: (p["indexCount"] as? Int) ?? 0)
            parsedParts.append(part)
        }
        self.parts = parsedParts
        var parsedClips: [String: Clip] = [:]
        var tips: [SIMD3<Double>] = [SIMD3<Double>](repeating: SIMD3<Double>(0, 0, 0), count: frames)
        var dirs: [SIMD3<Double>] = [SIMD3<Double>](repeating: SIMD3<Double>(0, 0, 1), count: frames)
        var heads: [[Double]] = [[Double]](repeating: ManAssets.identity, count: frames)
        var spines: [[Double]] = [[Double]](repeating: ManAssets.identity, count: frames)
        for a in animList {
            guard let name = a["name"] as? String, let start = a["start"] as? Int, let n = a["frames"] as? Int else { continue }
            parsedClips[name] = Clip(name: name, start: start, frames: n)
            let anchors: [[Double]] = (a["anchors"] as? [[Double]]) ?? []
            let hm: [[Double]] = (a["head_m"] as? [[Double]]) ?? []
            let sm: [[Double]] = (a["spine_m"] as? [[Double]]) ?? []
            var k: Int = 0
            while k < n {
                let g: Int = start + k
                if k < anchors.count && anchors[k].count >= 6 && g < frames {
                    tips[g] = SIMD3<Double>(anchors[k][0], anchors[k][1], anchors[k][2])
                    dirs[g] = SIMD3<Double>(anchors[k][3], anchors[k][4], anchors[k][5])
                }
                if k < hm.count && hm[k].count >= 12 && g < frames { heads[g] = hm[k] }
                if k < sm.count && sm[k].count >= 12 && g < frames { spines[g] = sm[k] }
                k += 1
            }
        }
        self.clips = parsedClips
        self.anchorTip = tips
        self.anchorDir = dirs
        self.headMatrices = heads
        self.spineMatrices = spines
        self.variants = ManVariant.load()
        self.extras = SoupFile(bin: "ninja.bin", json: "ninja.json")
        buildSharedSources()
    }

    static let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0]

    // MARK: - clips and anchors

    func clip(_ name: String) -> Clip {
        return clips[name] ?? Clip(name: name, start: 0, frames: 1)
    }

    /// Cue tip and direction (character frame) of a global frame.
    func anchor(frame: Int) -> (tip: SIMD3<Double>, dir: SIMD3<Double>) {
        let f: Int = min(max(frame, 0), anchorTip.count - 1)
        return (anchorTip[f], anchorDir[f])
    }

    /// 12 numbers (3 rows of a 3x4 matrix, row major) of the head (`spine == false`) or spine bone's movement in a global frame.
    func boneMatrix(frame: Int, spine: Bool) -> [Double] {
        let f: Int = min(max(frame, 0), anchorTip.count - 1)
        return spine ? spineMatrices[f] : headMatrices[f]
    }

    // MARK: - geometry

    private func buildSharedSources() {
        bin.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            for part in parts {
                let uvOffset: Int = uvBase + part.uvByteOffset
                var uv: [Float] = [Float](repeating: 0, count: part.vertexCount * 2)
                var i: Int = 0
                while i < uv.count {
                    uv[i] = raw.loadUnaligned(fromByteOffset: uvOffset + i * 4, as: Float.self)
                    i += 1
                }
                uvSources.append(MeshKit.vertexSource(MeshKit.texcoords(uv), count: part.vertexCount, semantic: .texcoord, components: 2))
                let idxOffset: Int = indexBase + part.indexByteOffset
                var idx: [UInt32] = [UInt32](repeating: 0, count: part.indexCount)
                var k: Int = 0
                while k < idx.count {
                    idx[k] = raw.loadUnaligned(fromByteOffset: idxOffset + k * 4, as: UInt32.self)
                    k += 1
                }
                elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
            }
        }
    }

    /// Dequantised positions and normals of one part for a weighted mix of frames (weights sum to 1).
    func mixedArrays(part: Int, weights: [(frame: Int, weight: Float)]) -> (positions: [Float], normals: [Float]) {
        let p: Part = parts[part]
        let n: Int = p.vertexCount * 3
        var pos: [Float] = [Float](repeating: 0, count: n)
        var nrm: [Float] = [Float](repeating: 0, count: n)
        bin.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Void in
            for w in weights {
                let posStart: Int = posBase + (w.frame * vertexTotal + p.vertexOffset) * 6
                let nrmStart: Int = nrmBase + (w.frame * vertexTotal + p.vertexOffset) * 3
                let ps: Float = quant * w.weight
                let ns: Float = w.weight / 127.0
                var i: Int = 0
                while i < n {
                    let q: Int16 = raw.loadUnaligned(fromByteOffset: posStart + i * 2, as: Int16.self)
                    pos[i] += Float(q) * ps
                    let nv: Int8 = raw.loadUnaligned(fromByteOffset: nrmStart + i, as: Int8.self)
                    nrm[i] += Float(nv) * ns
                    i += 1
                }
            }
        }
        return (pos, nrm)
    }

    /// A geometry of one part for a weighted mix of frames. A single whole frame is built once and cached (sources are shared by every person).
    func geometry(part: Int, weights: [(frame: Int, weight: Float)]) -> SCNGeometry {
        var sources: [SCNGeometrySource]
        if weights.count == 1 {
            let key: Int = weights[0].frame * parts.count + part
            if let cached = staticSources[key] {
                sources = cached
            } else {
                let arrays = mixedArrays(part: part, weights: [(frame: weights[0].frame, weight: 1.0)])
                let count: Int = parts[part].vertexCount
                sources = [MeshKit.vertexSource(arrays.positions, count: count, semantic: .vertex, components: 3),
                           MeshKit.vertexSource(arrays.normals, count: count, semantic: .normal, components: 3)]
                staticSources[key] = sources
            }
        } else {
            let arrays = mixedArrays(part: part, weights: weights)
            let count: Int = parts[part].vertexCount
            sources = [MeshKit.vertexSource(arrays.positions, count: count, semantic: .vertex, components: 3),
                       MeshKit.vertexSource(arrays.normals, count: count, semantic: .normal, components: 3)]
        }
        sources.append(uvSources[part])
        return SCNGeometry(sources: sources, elements: [elements[part]])
    }
}
