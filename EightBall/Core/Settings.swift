import Foundation
import Combine

/// Graphics quality presets. Everything the frame rate depends on is derived from this (see `QualityProfile`).
enum Quality: String, CaseIterable, Codable, Identifiable {
    case low, medium, high, ultra

    var id: String { return rawValue }

    var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .ultra: return "Ultra"
        }
    }
}

/// How well the AI opponent plays.
enum Difficulty: String, CaseIterable, Codable, Identifiable {
    case easy, medium, hard

    var id: String { return rawValue }

    var title: String {
        switch self {
        case .easy: return "Easy"
        case .medium: return "Medium"
        case .hard: return "Hard"
        }
    }
}

/// The values behind a quality preset (the same table as pg_settings.py in the Python game).
struct QualityProfile {
    let shadows: Bool
    let shadowMapSize: Int
    let msaaSamples: Int
    let ballSegments: Int
    let reflections: Bool
    let dynamicPeople: Int      // how many people get smooth in-between poses every frame (the others snap to the nearest baked frame)
    let contactShadowAlpha: Double
    let maxFPS: Int

    static func make(_ q: Quality) -> QualityProfile {
        switch q {
        case .low:
            return QualityProfile(shadows: false, shadowMapSize: 512, msaaSamples: 1, ballSegments: 16, reflections: false, dynamicPeople: 0, contactShadowAlpha: 0.55, maxFPS: 60)
        case .medium:
            return QualityProfile(shadows: false, shadowMapSize: 512, msaaSamples: 2, ballSegments: 24, reflections: false, dynamicPeople: 2, contactShadowAlpha: 0.45, maxFPS: 60)
        case .high:
            return QualityProfile(shadows: true, shadowMapSize: 1024, msaaSamples: 4, ballSegments: 32, reflections: true, dynamicPeople: 2, contactShadowAlpha: 0.22, maxFPS: 60)
        case .ultra:
            return QualityProfile(shadows: true, shadowMapSize: 2048, msaaSamples: 4, ballSegments: 48, reflections: true, dynamicPeople: 2, contactShadowAlpha: 0.18, maxFPS: 120)
        }
    }
}

/// The settings screen's values; saved in UserDefaults whenever one changes.
@MainActor
final class GameSettings: ObservableObject {
    @Published var quality: Quality { didSet { save() } }
    @Published var difficulty: Difficulty { didSet { save() } }
    /// Touch aiming sensitivity, 0.3 (slow, precise) ... 2.0 (fast).
    @Published var sensitivity: Double { didSet { save() } }
    /// Master volume 0 ... 1.
    @Published var volume: Double { didSet { save() } }
    /// Show the aim guide (the line, the ghost ball and the paths). The level itself depends on the difficulty.
    @Published var aimGuide: Bool { didSet { save() } }
    @Published var haptics: Bool { didSet { save() } }
    @Published var showFPS: Bool { didSet { save() } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = UserDefaults.standard) {
        self.defaults = defaults
        let q = defaults.string(forKey: "quality").flatMap { Quality(rawValue: $0) } ?? Quality.high
        let d = defaults.string(forKey: "difficulty").flatMap { Difficulty(rawValue: $0) } ?? Difficulty.medium
        self.quality = q
        self.difficulty = d
        self.sensitivity = defaults.object(forKey: "sensitivity") != nil ? defaults.double(forKey: "sensitivity") : 1.0
        self.volume = defaults.object(forKey: "volume") != nil ? defaults.double(forKey: "volume") : 0.8
        self.aimGuide = defaults.object(forKey: "aimGuide") != nil ? defaults.bool(forKey: "aimGuide") : true
        self.haptics = defaults.object(forKey: "haptics") != nil ? defaults.bool(forKey: "haptics") : true
        self.showFPS = defaults.object(forKey: "showFPS") != nil ? defaults.bool(forKey: "showFPS") : false
    }

    var profile: QualityProfile { return QualityProfile.make(quality) }

    /// 0 = no guide, 1 = the line only, 2 = + ghost ball and the object ball's path, 3 = + the cue ball's path and the bounce.
    var guideLevel: Int {
        if !aimGuide { return 0 }
        switch difficulty {
        case .easy: return 3
        case .medium: return 2
        case .hard: return 1
        }
    }

    private func save() {
        defaults.set(quality.rawValue, forKey: "quality")
        defaults.set(difficulty.rawValue, forKey: "difficulty")
        defaults.set(sensitivity, forKey: "sensitivity")
        defaults.set(volume, forKey: "volume")
        defaults.set(aimGuide, forKey: "aimGuide")
        defaults.set(haptics, forKey: "haptics")
        defaults.set(showFPS, forKey: "showFPS")
    }
}
