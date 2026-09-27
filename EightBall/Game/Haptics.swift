import Foundation
import UIKit

/// Small taps for the important moments (the cue hits the ball, a ball drops, a foul, the game ends). Off when the setting is off.
@MainActor
final class Haptics {
    var enabled: Bool = true
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let notify = UINotificationFeedbackGenerator()

    func prepare() {
        light.prepare()
        medium.prepare()
        heavy.prepare()
        notify.prepare()
    }

    /// strength 0 ... 1 (the cue speed).
    func hit(strength: Double) {
        if !enabled { return }
        if strength > 0.66 {
            heavy.impactOccurred()
        } else if strength > 0.33 {
            medium.impactOccurred()
        } else {
            light.impactOccurred()
        }
    }

    func pocket() {
        if !enabled { return }
        medium.impactOccurred()
    }

    func foul() {
        if !enabled { return }
        notify.notificationOccurred(.warning)
    }

    func win() {
        if !enabled { return }
        notify.notificationOccurred(.success)
    }

    func lose() {
        if !enabled { return }
        notify.notificationOccurred(.error)
    }
}
