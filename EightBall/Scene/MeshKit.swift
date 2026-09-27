import Foundation
import SceneKit
import UIKit
import simd

/// Builds SceneKit geometry from plain arrays (the exported triangle soups, quads, ribbons) and materials from `Look`s.
enum MeshKit {
    /// The exported texture coordinates come from Panda3D / Blender (v points up); SceneKit on Metal has v pointing down.
    /// If textures ever look upside down on a device, flip this one switch.
    static let flipV: Bool = true

    // MARK: - vertex data

    static func vertexSource(_ values: [Float], count: Int, semantic: SCNGeometrySource.Semantic, components: Int) -> SCNGeometrySource {
        let data: Data = values.withUnsafeBufferPointer { (buf: UnsafeBufferPointer<Float>) -> Data in
            return Data(buffer: buf)
        }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                                 componentsPerVector: components, bytesPerComponent: MemoryLayout<Float>.size, dataOffset: 0,
                                 dataStride: components * MemoryLayout<Float>.size)
    }

    /// v -> 1 - v when `flipV` is on (u, v pairs).
    static func texcoords(_ uv: [Float]) -> [Float] {
        if !flipV { return uv }
        var out: [Float] = uv
        var i: Int = 1
        while i < out.count {
            out[i] = 1.0 - out[i]
            i += 2
        }
        return out
    }

    static func sequentialIndices(_ count: Int) -> [UInt32] {
        var idx: [UInt32] = []
        idx.reserveCapacity(count)
        var i: Int = 0
        while i < count {
            idx.append(UInt32(i))
            i += 1
        }
        return idx
    }

    /// A triangle list from flat position / normal / uv arrays (`uvs` is in the Python / Blender convention, see `flipV`).
    static func geometry(positions: [Float], normals: [Float], uvs: [Float]?, indices: [UInt32]) -> SCNGeometry {
        let count: Int = positions.count / 3
        var sources: [SCNGeometrySource] = []
        sources.append(vertexSource(positions, count: count, semantic: .vertex, components: 3))
        sources.append(vertexSource(normals, count: count, semantic: .normal, components: 3))
        if let uv = uvs {
            sources.append(vertexSource(texcoords(uv), count: count, semantic: .texcoord, components: 2))
        }
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        return SCNGeometry(sources: sources, elements: [element])
    }

    /// Triangle soup: every three consecutive vertices are one triangle.
    static func soup(positions: [Float], normals: [Float], uvs: [Float]) -> SCNGeometry {
        let count: Int = positions.count / 3
        return geometry(positions: positions, normals: normals, uvs: uvs, indices: sequentialIndices(count))
    }

    /// One rectangle from four corners (counter clockwise seen from the normal side); uv runs 0 ... uvScale.
    static func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, normal: SIMD3<Float>, uvScale: SIMD2<Float> = SIMD2<Float>(1, 1)) -> SCNGeometry {
        let positions: [Float] = [a.x, a.y, a.z, b.x, b.y, b.z, c.x, c.y, c.z, d.x, d.y, d.z]
        var normals: [Float] = []
        for _ in 0..<4 {
            normals.append(normal.x)
            normals.append(normal.y)
            normals.append(normal.z)
        }
        let uvs: [Float] = [0, 0, uvScale.x, 0, uvScale.x, uvScale.y, 0, uvScale.y]
        return geometry(positions: positions, normals: normals, uvs: uvs, indices: [0, 1, 2, 0, 2, 3])
    }

    /// A flat strip along a polyline in the XY plane (game coordinates), `width` metres wide, at height `z`; used by the aim guide.
    /// Returns the positions / indices to append to; `first` is the running vertex count.
    static func appendRibbon(_ points: [SIMD2<Double>], width: Double, z: Double, positions: inout [Float], indices: inout [UInt32]) {
        if points.count < 2 { return }
        let half: Double = width / 2.0
        let base: UInt32 = UInt32(positions.count / 3)
        var i: Int = 0
        while i < points.count {
            let prev: SIMD2<Double> = points[max(i - 1, 0)]
            let next: SIMD2<Double> = points[min(i + 1, points.count - 1)]
            var dir: SIMD2<Double> = next - prev
            let len: Double = (dir.x * dir.x + dir.y * dir.y).squareRoot()
            if len < 1e-9 {
                dir = SIMD2<Double>(1, 0)
            } else {
                dir = dir / len
            }
            let nx: Double = -dir.y * half
            let ny: Double = dir.x * half
            let p: SIMD2<Double> = points[i]
            positions.append(Float(p.x + nx))
            positions.append(Float(p.y + ny))
            positions.append(Float(z))
            positions.append(Float(p.x - nx))
            positions.append(Float(p.y - ny))
            positions.append(Float(z))
            i += 1
        }
        var s: Int = 0
        while s < points.count - 1 {
            let a: UInt32 = base + UInt32(s * 2)
            indices.append(contentsOf: [a, a + 1, a + 2, a + 1, a + 3, a + 2])
            s += 1
        }
    }

    // MARK: - materials

    /// How one surface looks: texture (a path inside Data/), tint, specular strength, shininess, unlit (emissive).
    struct Look {
        var texture: String?
        var color: SIMD3<Float>
        var spec: Float
        var shine: Float
        var emissive: Bool
        var mirrored: Bool

        init(texture: String? = nil, color: SIMD3<Float> = SIMD3<Float>(1, 1, 1), spec: Float = 0, shine: Float = 10, emissive: Bool = false, mirrored: Bool = false) {
            self.texture = texture
            self.color = color
            self.spec = spec
            self.shine = shine
            self.emissive = emissive
            self.mirrored = mirrored
        }
    }

    static func uiColor(_ c: SIMD3<Float>, alpha: CGFloat = 1) -> UIColor {
        return UIColor(red: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: alpha)
    }

    static func material(_ look: Look, anisotropy: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = look.emissive ? SCNMaterial.LightingModel.constant : SCNMaterial.LightingModel.blinn
        var textured: Bool = false
        if let path = look.texture, let img = DataStore.image(path) {
            textured = true
            m.diffuse.contents = img
            let wrap: SCNWrapMode = look.mirrored ? SCNWrapMode.mirror : SCNWrapMode.repeat
            m.diffuse.wrapS = wrap
            m.diffuse.wrapT = wrap
            m.diffuse.mipFilter = SCNFilterMode.linear
            m.diffuse.minificationFilter = SCNFilterMode.linear
            m.diffuse.magnificationFilter = SCNFilterMode.linear
            m.diffuse.maxAnisotropy = anisotropy
        }
        if textured {
            if look.color != SIMD3<Float>(1, 1, 1) {
                m.multiply.contents = uiColor(look.color)
            }
        } else {
            m.diffuse.contents = uiColor(look.color)
        }
        m.specular.contents = UIColor(white: CGFloat(look.spec), alpha: 1)
        m.shininess = CGFloat(look.shine)
        return m
    }

    /// A flat, unlit material with a texture and alpha (decals, contact shadows, prints).
    static func decalMaterial(_ path: String, tint: CGFloat = 1, alpha: CGFloat = 1) -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = SCNMaterial.LightingModel.constant
        m.diffuse.contents = DataStore.image(path)
        m.diffuse.wrapS = SCNWrapMode.clamp
        m.diffuse.wrapT = SCNWrapMode.clamp
        m.multiply.contents = UIColor(white: tint, alpha: 1)
        m.transparency = alpha
        m.blendMode = SCNBlendMode.alpha
        m.writesToDepthBuffer = false
        m.transparencyMode = SCNTransparencyMode.aOne
        return m
    }

    /// A plain unlit colour (the aim guide).
    static func flatMaterial(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.isDoubleSided = true
        m.lightingModel = SCNMaterial.LightingModel.constant
        m.diffuse.contents = color
        m.blendMode = SCNBlendMode.alpha
        m.writesToDepthBuffer = false
        m.readsFromDepthBuffer = true
        return m
    }
}

/// The triangle soups Blender exported (models.bin / models.json, ninja.bin / ninja.json): model -> material name -> arrays.
struct SoupPart {
    let positions: [Float]
    let normals: [Float]
    let uvs: [Float]
}

final class SoupFile {
    /// group ("table", "lamp", "cue", "chalk" / "head", "back") -> material name -> triangle soup
    let groups: [String: [String: SoupPart]]

    init(bin: String, json: String) {
        var result: [String: [String: SoupPart]] = [:]
        if let data = DataStore.data(bin), let meta = DataStore.json(json) as? [String: Any] {
            let all: [Float] = data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Float] in
                return Array(raw.bindMemory(to: Float.self))
            }
            for (group, mats) in meta {
                guard let matDict = mats as? [String: Any] else { continue }
                var parts: [String: SoupPart] = [:]
                for (name, range) in matDict {
                    guard let r = range as? [Any], r.count == 2, let offset = r[0] as? Int, let count = r[1] as? Int else { continue }
                    var pos: [Float] = []
                    var nrm: [Float] = []
                    var uv: [Float] = []
                    pos.reserveCapacity(count * 3)
                    nrm.reserveCapacity(count * 3)
                    uv.reserveCapacity(count * 2)
                    var k: Int = 0
                    while k < count {
                        let b: Int = (offset + k) * 8
                        pos.append(all[b])
                        pos.append(all[b + 1])
                        pos.append(all[b + 2])
                        nrm.append(all[b + 3])
                        nrm.append(all[b + 4])
                        nrm.append(all[b + 5])
                        uv.append(all[b + 6])
                        uv.append(all[b + 7])
                        k += 1
                    }
                    parts[name] = SoupPart(positions: pos, normals: nrm, uvs: uv)
                }
                result[group] = parts
            }
        }
        self.groups = result
    }
}
