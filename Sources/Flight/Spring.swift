import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// A spring, described the way SwiftUI describes one: how long it takes to respond and how
/// much it bounces (0 settles without overshooting).
public struct FlightSpring: Sendable, Hashable {
    public var response: Double
    public var dampingRatio: Double

    public init(response: Double, dampingRatio: Double = 1) {
        self.response = response
        self.dampingRatio = dampingRatio
    }

    /// Opening and closing: quick, no overshoot.
    public static let transition = FlightSpring(response: 0.36, dampingRatio: 1)
    /// Going back after a drag that did not close: quick, a hint of bounce.
    public static let restore = FlightSpring(response: 0.32, dampingRatio: 0.86)

    public var stiffness: Double { pow(2 * .pi / max(response, 0.01), 2) }
    public var damping: Double { 4 * .pi * dampingRatio / max(response, 0.01) }
}

/// Springs a vector of values toward targets, one frame at a time. Retargeting keeps each
/// value's current velocity, so an animation can change course mid-flight without a jolt.
public struct SpringVector: Sendable {
    public private(set) var values: [Double]
    public private(set) var velocities: [Double]
    public private(set) var targets: [Double]
    public var spring: FlightSpring
    public let tolerances: [Double]

    public init(values: [Double], tolerances: [Double], spring: FlightSpring) {
        self.values = values
        self.velocities = Array(repeating: 0, count: values.count)
        self.targets = values
        self.tolerances = tolerances
        self.spring = spring
    }

    public mutating func set(values: [Double], velocities: [Double]? = nil) {
        self.values = values
        self.velocities = velocities ?? Array(repeating: 0, count: values.count)
    }

    /// Moves the targets by `delta`, and the values by `carried` of it: a value carried
    /// all the way moves rigidly with its target, keeping its distance and velocity.
    public mutating func shift(_ delta: [Double], carried: Double) {
        for i in values.indices {
            targets[i] += delta[i]
            values[i] += delta[i] * carried
        }
    }

    public mutating func retarget(_ targets: [Double], spring: FlightSpring? = nil) {
        self.targets = targets
        if let spring { self.spring = spring }
    }

    public var isSettled: Bool {
        for i in values.indices {
            let tol = tolerances[i]
            if abs(values[i] - targets[i]) > tol || abs(velocities[i]) > tol * 20 { return false }
        }
        return true
    }

    /// Advances by `dt` seconds; returns whether the values have come to rest (and snaps them to the targets if so).
    public mutating func step(_ dt: Double) -> Bool {
        let k = spring.stiffness, c = spring.damping
        // Semi-implicit Euler in small fixed steps: stable for stiff springs at any frame rate.
        var remaining = min(dt, 1.0 / 20)
        let h = 1.0 / 960
        while remaining > 1e-9 {
            let s = min(h, remaining)
            for i in values.indices {
                let a = -k * (values[i] - targets[i]) - c * velocities[i]
                velocities[i] += a * s
                values[i] += velocities[i] * s
            }
            remaining -= s
        }
        if isSettled {
            values = targets
            velocities = Array(repeating: 0, count: values.count)
            return true
        }
        return false
    }
}

/// Calls back once per display frame while running, with the time to advance by.
///
/// The callback runs late in the frame, just before its layout and commit. By then scroll views
/// have moved for this frame, so an image placed relative to content on screen is placed where
/// the content is now, not where it was a frame ago (which reads as the image drifting).
///
/// On iOS 18 and later it is a UI update link (`UIUpdateLink`), acting in the update's last phase
/// before the commit. Before that (and on the Mac) a display link says a frame is due and the
/// callback waits for the end of that turn of the run loop.
///
/// Either asks for 120 frames a second, and a phone takes that as a wish: an iPhone Air paging a
/// branch gave the display link 80, and the update link 120 the first time and 80 the next two.
/// What it went by every time is an animation asking for 120: so while the clock runs, the window
/// holds one that changes nothing, on a point that draws nothing (`paces`).
@MainActor
public final class FlightClock: NSObject {
    private let tick: (Double) -> Void
    private var lastTimestamp: CFTimeInterval?
    private var pending: Double?
    private var link: CADisplayLink?
    private var observer: CFRunLoopObserver?
    /// The UI update link, while running (an `UIUpdateLink`, kept untyped for systems before it).
    private var updateLink: AnyObject?
    /// Whether running clocks hold an animation in the window asking for their rate. Off only to see
    /// what they get without it.
    public static var paces = true
    /// The layer holding this clock's animation, while it runs.
    private var pacer: CALayer?
    #if !canImport(UIKit)
    private weak var view: NSView?
    #endif

    #if canImport(UIKit)
    public init(tick: @escaping (Double) -> Void) {
        self.tick = tick
    }
    #else
    public init(view: NSView, tick: @escaping (Double) -> Void) {
        self.view = view
        self.tick = tick
    }
    #endif

    public var isRunning: Bool { link != nil || updateLink != nil }

    public func start() {
        guard !isRunning else { return }
        lastTimestamp = nil
        pending = nil
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 18, tvOS 18, visionOS 2, *), let scene = Self.scene() {
            let updateLink = UIUpdateLink(windowScene: scene)
            #if os(visionOS)
            let frame = 1.0 / 90
            #else
            let frame = 1.0 / Double(max(scene.screen.maximumFramesPerSecond, 1))
            #endif
            updateLink.addAction(to: .beforeCATransactionCommit) { [weak self] _, info in
                guard let self else { return }
                let now = info.modelTime
                let dt = self.lastTimestamp.map { now - $0 } ?? frame
                self.lastTimestamp = now
                self.tick(max(dt, 1.0 / 240))
            }
            // Only once it has an action: asking for continuous updates without one is a crash.
            updateLink.requiresContinuousUpdates = true
            updateLink.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
            updateLink.isEnabled = true
            self.updateLink = updateLink
            pace(scene)
            return
        }
        #endif
        #if canImport(UIKit)
        let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.fire(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        #else
        guard let view else { return }
        let link = view.displayLink(target: WeakTarget(self), selector: #selector(WeakTarget.fire(_:)))
        #endif
        link.add(to: .main, forMode: .common)
        self.link = link
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        if let scene = Self.scene() { pace(scene) }
        #endif

        // Before the layout pass and the Core Animation commit (order 2,000,000) of the same turn.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_998_000) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.flush() }
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    #if canImport(UIKit) && !targetEnvironment(macCatalyst)
    /// The scene on screen: the clock has no view of its own, and a person looks at one scene at a time.
    private static func scene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first { $0.activationState == .foregroundInactive }
    }

    /// An animation that changes nothing and asks for 120 frames a second, for as long as the clock runs: on a layer
    /// of its own in the window, a point that draws nothing. (On the window's own layer, an opacity animation had the
    /// whole window drawn offscreen every frame: 13 passes where there was 1, and 2.5 ms more of the GPU.)
    private func pace(_ scene: UIWindowScene) {
        guard Self.paces, let window = scene.keyWindow ?? scene.windows.first else { return }
        let pacer = CALayer()
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.isAdditive = true
        animation.fromValue = 0
        animation.toValue = 0
        animation.duration = 1
        animation.repeatCount = .infinity
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 120, maximum: 120, preferred: 120)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pacer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        window.layer.addSublayer(pacer)
        pacer.add(animation, forKey: "pace")
        CATransaction.commit()
        self.pacer = pacer
    }
    #endif

    public func stop() {
        #if canImport(UIKit) && !targetEnvironment(macCatalyst)
        if #available(iOS 18, tvOS 18, visionOS 2, *), let updateLink = updateLink as? UIUpdateLink {
            updateLink.isEnabled = false
        }
        #endif
        updateLink = nil
        link?.invalidate()
        link = nil
        if let pacer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            pacer.removeFromSuperlayer()
            CATransaction.commit()
            self.pacer = nil
        }
        if let observer {
            CFRunLoopObserverInvalidate(observer)
            self.observer = nil
        }
        lastTimestamp = nil
        pending = nil
    }

    fileprivate func fire(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        let dt = lastTimestamp.map { now - $0 } ?? (link.targetTimestamp - link.timestamp)
        lastTimestamp = now
        pending = (pending ?? 0) + max(dt, 1.0 / 240)
    }

    private func flush() {
        guard let dt = pending else { return }
        pending = nil
        tick(dt)
    }
}

/// Keeps the display link from retaining the ticker.
private final class WeakTarget: NSObject {
    weak var ticker: FlightClock?
    init(_ ticker: FlightClock) { self.ticker = ticker }
    @MainActor @objc func fire(_ link: CADisplayLink) { ticker?.fire(link) }
}
