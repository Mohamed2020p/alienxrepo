import UIKit
import SwiftUI
import SceneKit
import Combine

/// Full-screen SceneKit view (the 3D lounge and the game) with the SwiftUI overlay (`RootView`) on top.
/// The touch gestures live on the SCNView; the SwiftUI layers only catch touches on their own buttons and panels.
@MainActor
final class GameViewController: UIViewController, UIGestureRecognizerDelegate {
    private let settings: GameSettings
    private let game: GameController
    private let sceneView: SCNView

    private var hosting: UIHostingController<RootView>?
    private var orbitRecognizer: UIPanGestureRecognizer?
    private var pinchRecognizer: UIPinchGestureRecognizer?

    private var lastAimTranslation: CGPoint = CGPoint.zero
    private var lastOrbitTranslation: CGPoint = CGPoint.zero
    private var lastPinchScale: CGFloat = 1.0

    init(settings: GameSettings) {
        self.settings = settings
        self.game = GameController(settings: settings)
        self.sceneView = SCNView(frame: CGRect.zero)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        let dark: UIColor = UIColor(red: 10.0 / 255.0, green: 22.0 / 255.0, blue: 34.0 / 255.0, alpha: 1.0)
        view.backgroundColor = dark

        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.backgroundColor = dark
        sceneView.isMultipleTouchEnabled = true
        view.addSubview(sceneView)
        game.attach(to: sceneView)
        addGestureRecognizers()

        let root: RootView = RootView(model: game.model, settings: settings, commands: game)
        let host: UIHostingController<RootView> = UIHostingController(rootView: root)
        host.view.backgroundColor = UIColor.clear
        host.view.isOpaque = false
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        hosting = host

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(appWillResignActive),
                                               name: UIApplication.willResignActiveNotification,
                                               object: nil)
    }

    override var prefersStatusBarHidden: Bool {
        return true
    }

    override var prefersHomeIndicatorAutoHidden: Bool {
        return true
    }

    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return UIRectEdge.bottom
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.landscape
    }

    override var shouldAutorotate: Bool {
        return true
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return UIInterfaceOrientation.landscapeRight
    }

    // MARK: App state

    @objc private func appWillResignActive() {
        if game.model.screen == ScreenPhase.playing {
            game.pauseGame()
        }
    }

    // MARK: Gestures

    private func addGestureRecognizers() {
        let aim: UIPanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleAimPan(_:)))
        aim.minimumNumberOfTouches = 1
        aim.maximumNumberOfTouches = 1
        aim.delegate = self
        sceneView.addGestureRecognizer(aim)

        let orbit: UIPanGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(handleOrbitPan(_:)))
        orbit.minimumNumberOfTouches = 2
        orbit.maximumNumberOfTouches = 2
        orbit.delegate = self
        sceneView.addGestureRecognizer(orbit)
        orbitRecognizer = orbit

        let pinch: UIPinchGestureRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        sceneView.addGestureRecognizer(pinch)
        pinchRecognizer = pinch
    }

    /// The two-finger pan and the pinch may run together (orbit while zooming); nothing else may.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        let isOrbit: Bool = gestureRecognizer === orbitRecognizer || otherGestureRecognizer === orbitRecognizer
        let isPinch: Bool = gestureRecognizer === pinchRecognizer || otherGestureRecognizer === pinchRecognizer
        return isOrbit && isPinch
    }

    @objc private func handleAimPan(_ g: UIPanGestureRecognizer) {
        if game.model.screen != ScreenPhase.playing {
            return
        }
        let t: CGPoint = g.translation(in: sceneView)
        let placing: Bool = game.model.placingBall
        switch g.state {
        case .began:
            lastAimTranslation = t
            if placing {
                game.dragPlace(to: g.location(in: sceneView), in: sceneView)
            }
        case .changed:
            let dx: CGFloat = t.x - lastAimTranslation.x
            let dy: CGFloat = t.y - lastAimTranslation.y
            lastAimTranslation = t
            game.dragAim(dx: Double(dx), dy: Double(dy))
            if placing {
                game.dragPlace(to: g.location(in: sceneView), in: sceneView)
            }
        default:
            break
        }
    }

    @objc private func handleOrbitPan(_ g: UIPanGestureRecognizer) {
        if game.model.screen != ScreenPhase.playing {
            return
        }
        let t: CGPoint = g.translation(in: sceneView)
        switch g.state {
        case .began:
            lastOrbitTranslation = t
        case .changed:
            let dx: CGFloat = t.x - lastOrbitTranslation.x
            let dy: CGFloat = t.y - lastOrbitTranslation.y
            lastOrbitTranslation = t
            game.dragOrbit(dx: Double(dx), dy: Double(dy))
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if game.model.screen != ScreenPhase.playing {
            return
        }
        switch g.state {
        case .began:
            lastPinchScale = 1.0
        case .changed:
            let s: CGFloat = g.scale
            let previous: CGFloat = lastPinchScale
            lastPinchScale = s
            if previous > 0.0001 && s > 0.0001 {
                let ratio: CGFloat = s / previous
                game.pinch(scale: Double(ratio))
            }
        default:
            break
        }
    }
}
