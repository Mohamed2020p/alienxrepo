import Foundation
import AVFoundation

/// Sound: one-shots (balls, cushions, pockets, footsteps, the cue ...) from a pool of players per sound, and looping ambience that fades to its target volume.
/// Every sound was synthesised for the game (Resources/Audio/*.wav).
@MainActor
final class AudioManager {
    private static let poolSize: Int = 6

    private var pools: [String: [AVAudioPlayer]] = [:]
    private var loops: [String: AVAudioPlayer] = [:]
    private var loopTarget: [String: Float] = [:]
    private var loopCurrent: [String: Float] = [:]
    private var master: Float = 0.8

    init(volume: Double) {
        master = Float(volume)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(AVAudioSession.Category.ambient, mode: AVAudioSession.Mode.default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            // no audio session: the game stays silent
        }
    }

    func setVolume(_ v: Double) {
        master = Float(max(0.0, min(1.0, v)))
        for (name, player) in loops {
            player.volume = (loopCurrent[name] ?? 0) * master
        }
    }

    private func makePlayer(_ name: String) -> AVAudioPlayer? {
        let url: URL = DataStore.audioRoot.appendingPathComponent(name + ".wav")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return nil }
        player.enableRate = true
        player.prepareToPlay()
        return player
    }

    /// Plays a one-shot; `variants` > 1 picks name_1 ... name_n at random.
    func play(_ base: String, volume: Double = 1.0, rate: Double = 1.0, variants: Int = 1) {
        var name: String = base
        if variants > 1 {
            name = base + "_" + String(Int.random(in: 1...variants))
        }
        var pool: [AVAudioPlayer] = pools[name] ?? []
        var chosen: AVAudioPlayer?
        for p in pool where !p.isPlaying {
            chosen = p
            break
        }
        if chosen == nil {
            if pool.count < AudioManager.poolSize {
                if let p = makePlayer(name) {
                    pool.append(p)
                    pools[name] = pool
                    chosen = p
                }
            } else {
                chosen = pool.first
            }
        }
        guard let player = chosen else { return }
        player.currentTime = 0
        player.rate = Float(max(0.5, min(2.0, rate)))
        player.volume = Float(max(0.0, min(1.0, volume))) * master
        player.play()
    }

    /// kind_soft / kind_med / kind_hard picked by the strength (0 ... 1) of the impact, louder when stronger.
    func tiered(_ kind: String, strength: Double, scale: Double = 1.0) {
        let tier: String = strength < 0.28 ? "soft" : (strength < 0.62 ? "med" : "hard")
        play(kind + "_" + tier, volume: (0.30 + 0.75 * strength) * scale, rate: Double.random(in: 0.96...1.05), variants: 3)
    }

    func footstep() {
        play("foot_carpet", volume: 0.42, rate: Double.random(in: 0.94...1.08), variants: 4)
    }

    /// Starts (once) or retargets a looping sound; its volume fades in `update`.
    func setLoop(_ name: String, volume: Double) {
        if loops[name] == nil {
            guard let p = makePlayer(name) else { return }
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            loops[name] = p
            loopCurrent[name] = 0
        }
        loopTarget[name] = Float(volume)
    }

    func update(dt: Double) {
        for (name, player) in loops {
            let target: Float = loopTarget[name] ?? 0
            var cur: Float = loopCurrent[name] ?? 0
            cur += (target - cur) * Float(min(1.0, 6.0 * dt))
            loopCurrent[name] = cur
            player.volume = cur * master
        }
    }
}
