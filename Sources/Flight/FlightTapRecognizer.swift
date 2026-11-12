#if canImport(UIKit)
import UIKit

/// A tap on something flying, caught without taking anything else's touches: it watches the
/// whole window (add it to the window), lets go at once of a touch that doesn't begin on the
/// flying thing (`contains`, in the window's coordinates), and goes along with every other
/// recognizer, so a pan or a scroll that starts on the flying thing moves the page under it.
/// Other taps wait for it, so a tap it takes isn't also a tap on what lies under.
@MainActor
public final class FlightTapRecognizer: UITapGestureRecognizer, UIGestureRecognizerDelegate {
    /// Whether a touch at this point of the window is on the flying thing.
    public var contains: (CGPoint) -> Bool = { _ in false }
    public var onTap: (() -> Void)?

    public init() {
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(tapped))
        delegate = self
        delaysTouchesEnded = false
    }

    /// Watches `window` (once; moved there if it watched another).
    public func watch(_ window: UIWindow) {
        guard view !== window else { return }
        view?.removeGestureRecognizer(self)
        window.addGestureRecognizer(self)
    }

    public func stopWatching() {
        view?.removeGestureRecognizer(self)
    }

    @objc private func tapped() {
        if state == .ended { onTap?() }
    }

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let window = view as? UIWindow ?? view?.window,
              touches.allSatisfy({ contains($0.location(in: window)) }) else {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        other is UITapGestureRecognizer
    }
}
#endif
