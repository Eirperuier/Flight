import CoreGraphics

/// How a thumbnail draws its image inside its frame, so the transition starts from exactly what was on screen.
public enum PreviewContentMode: Sendable, Hashable {
    /// The image fills the frame and is cropped (SwiftUI `scaledToFill`, UIKit `.scaleAspectFill`).
    case fill
    /// The whole image is visible inside the frame (SwiftUI `scaledToFit`, UIKit `.scaleAspectFit`).
    case fit
}

extension CGSize {
    var hasArea: Bool { width > 0 && height > 0 && width.isFinite && height.isFinite }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// The rect of an image of `size` placed in this rect with `mode`, centred.
    func placing(_ size: CGSize, _ mode: PreviewContentMode) -> CGRect {
        guard size.hasArea, width > 0, height > 0 else { return self }
        let sx = width / size.width, sy = height / size.height
        let scale = mode == .fill ? max(sx, sy) : min(sx, sy)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    /// This rect scaled by `scale` about `anchor`, then moved by `offset`.
    func scaled(_ scale: CGFloat, about anchor: CGPoint, offset: CGPoint = .zero) -> CGRect {
        CGRect(
            x: anchor.x + (minX - anchor.x) * scale + offset.x,
            y: anchor.y + (minY - anchor.y) * scale + offset.y,
            width: width * scale,
            height: height * scale
        )
    }
}

/// Where the moving image is during a transition or a drag: the whole image's rect, the
/// visible part of it (a thumbnail crops), the corner radius of that part, how dark the
/// backdrop is and how opaque the image is. Every value animates on the same spring, so a
/// transition can be interrupted and retargeted at any frame without a jump.
struct HeroState: Equatable {
    var image: CGRect
    var clip: CGRect
    var cornerRadius: CGFloat
    var backdrop: CGFloat
    var opacity: CGFloat

    static let count = 11

    var vector: [Double] {
        [image.minX, image.minY, image.width, image.height,
         clip.minX, clip.minY, clip.width, clip.height,
         cornerRadius, backdrop, opacity].map(Double.init)
    }

    init(image: CGRect, clip: CGRect, cornerRadius: CGFloat, backdrop: CGFloat, opacity: CGFloat = 1) {
        self.image = image
        self.clip = clip
        self.cornerRadius = cornerRadius
        self.backdrop = backdrop
        self.opacity = opacity
    }

    init(_ v: [Double]) {
        let c = v.map { CGFloat($0) }
        image = CGRect(x: c[0], y: c[1], width: max(c[2], 0), height: max(c[3], 0))
        clip = CGRect(x: c[4], y: c[5], width: max(c[6], 0), height: max(c[7], 0))
        cornerRadius = max(c[8], 0)
        backdrop = min(max(c[9], 0), 1)
        opacity = min(max(c[10], 0), 1)
    }

    /// The full-screen state: the image fitted to the container, nothing cropped.
    static func presented(_ fitted: CGRect) -> HeroState {
        HeroState(image: fitted, clip: fitted, cornerRadius: 0, backdrop: 1)
    }

    /// The thumbnail's state: the image placed in the thumbnail's frame as the thumbnail draws it.
    static func source(frame: CGRect, imageSize: CGSize, mode: PreviewContentMode, cornerRadius: CGFloat) -> HeroState {
        let image = frame.placing(imageSize, mode)
        return HeroState(image: image, clip: mode == .fill ? frame : image, cornerRadius: cornerRadius, backdrop: 0)
    }

    /// Where the image goes when there is no thumbnail to go to: a little smaller, fading out.
    static func vanished(from fitted: CGRect) -> HeroState {
        let r = fitted.scaled(0.86, about: fitted.center)
        return HeroState(image: r, clip: r, cornerRadius: 0, backdrop: 0, opacity: 0)
    }

    /// Part way from this to `other` (every value straight across).
    func mixed(with other: HeroState, _ t: CGFloat) -> HeroState {
        HeroState(zip(vector, other.vector).map { $0 + ($1 - $0) * Double(t) })
    }

    /// The same, moved so its clip's centre is at `point`.
    func centred(at point: CGPoint) -> HeroState {
        let dx = point.x - clip.midX, dy = point.y - clip.midY
        var moved = self
        moved.image = image.offsetBy(dx: dx, dy: dy)
        moved.clip = clip.offsetBy(dx: dx, dy: dy)
        return moved
    }

    /// Per value, how close counts as arrived: a fraction of a point for geometry, less for opacities.
    static let tolerances: [Double] = [0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.002, 0.002]

    /// The velocity of a drag carried into the image's and the clip's position as it heads for
    /// `target`: what already points there carries over whole; the rest (sideways, or away)
    /// only in part, so a flick bends into the landing instead of flying off and turning back.
    func velocity(_ velocity: CGPoint, toward target: HeroState) -> [Double] {
        let from = image.center, to = target.image.center
        let distance = hypot(to.x - from.x, to.y - from.y)
        var v = CGPoint(x: velocity.x * 0.3, y: velocity.y * 0.3)
        if distance > 1 {
            let d = CGPoint(x: (to.x - from.x) / distance, y: (to.y - from.y) / distance)
            let along = velocity.x * d.x + velocity.y * d.y
            if along > 0 {
                v = CGPoint(x: d.x * along + (velocity.x - d.x * along) * 0.3, y: d.y * along + (velocity.y - d.y * along) * 0.3)
            }
        }
        let speed = hypot(v.x, v.y), cap: CGFloat = 2500
        if speed > cap { v = CGPoint(x: v.x * cap / speed, y: v.y * cap / speed) }
        var out = [Double](repeating: 0, count: Self.count)
        out[0] = v.x; out[1] = v.y; out[4] = v.x; out[5] = v.y
        return out
    }
}

/// How the image follows a drag that would close it: it moves with the finger, shrinks
/// as it gets farther from where it started (about the point that was grabbed, so that point
/// stays under the finger), and the backdrop lightens to show what is underneath.
struct DismissDrag {
    /// Which way the drag closes: up or down, or past the first or last image sideways.
    enum Axis: Equatable {
        case vertical
        /// Rightward, past the first image.
        case right
        /// Leftward, past the last image.
        case left
    }

    let start: HeroState
    let anchor: CGPoint
    let axis: Axis
    /// The container's size, which sets how far a drag goes before it is all the way out.
    let container: CGSize

    init(start: HeroState, anchor: CGPoint, axis: Axis = .vertical, container: CGSize) {
        self.start = start
        self.anchor = anchor
        self.axis = axis
        self.container = container
    }

    /// The axis a drag starting with `velocity` closes along, if it closes at all: up or down
    /// always; sideways only where there is no image to move to.
    static func axis(for velocity: CGPoint, index: Int, count: Int) -> Axis? {
        if abs(velocity.y) > abs(velocity.x) { return .vertical }
        if velocity.x > 0, index == 0 { return .right }
        if velocity.x < 0, index == count - 1 { return .left }
        return nil
    }

    private var extent: CGFloat { max(axis == .vertical ? container.height : container.width, 1) }

    /// How far the drag has gone in the way it closes, signed: negative is back past where it started.
    private func along(_ p: CGPoint) -> CGFloat {
        switch axis {
        case .vertical: p.y
        case .right: p.x
        case .left: -p.x
        }
    }

    /// How far the drag has gone toward closing (up and down both count).
    private func distance(_ t: CGPoint) -> CGFloat {
        axis == .vertical ? abs(t.y) : max(along(t), 0)
    }

    func state(translation t: CGPoint) -> HeroState {
        let d = distance(t)
        let progress = min(d / extent, 1)
        let scale = max(1 - progress * 0.8, 0.55)
        let backdrop = start.backdrop * max(1 - d / (extent * 0.7), 0)
        return HeroState(
            image: start.image.scaled(scale, about: anchor, offset: t),
            clip: start.clip.scaled(scale, about: anchor, offset: t),
            cornerRadius: start.cornerRadius * scale,
            backdrop: backdrop,
            opacity: start.opacity
        )
    }

    /// Whether letting go here closes the viewer: a flick away from the middle does; a flick
    /// back toward it does not; a slow release does once the image is a fair way out.
    func closes(translation t: CGPoint, velocity v: CGPoint) -> Bool {
        let a = along(t), va = along(v)
        if abs(va) > 700 { return axis == .vertical ? a * va >= 0 : va > 0 }
        return axis == .vertical ? abs(a) > extent * 0.22 : a > extent * 0.22
    }
}

/// Keeps an image flying home on course for its thumbnail while the thumbnail moves (the page
/// scrolls under it). The landing spot moves with the thumbnail; the image is carried along
/// by as much as it has arrived: barely while it is still large and far, rigidly as it lands.
/// So it neither lags behind the content nor swings after it, and lands exactly.
struct Landing {
    private(set) var frame: CGRect
    private let startDistance: Double

    init(frame: CGRect, springs: SpringVector) {
        self.frame = frame
        self.startDistance = max(Self.distance(springs), 1)
    }

    private static func distance(_ springs: SpringVector) -> Double {
        (0..<4).reduce(0) { $0 + abs(springs.values[$1] - springs.targets[$1]) }
    }

    /// Follows the thumbnail to `newFrame`. Returns false if it changed size, which a move
    /// does not do: then the caller works the landing out afresh.
    mutating func follow(_ newFrame: CGRect, springs: inout SpringVector) -> Bool {
        defer { frame = newFrame }
        guard abs(newFrame.width - frame.width) < 0.5, abs(newFrame.height - frame.height) < 0.5 else { return false }
        let dx = Double(newFrame.minX - frame.minX), dy = Double(newFrame.minY - frame.minY)
        guard dx != 0 || dy != 0 else { return true }
        var delta = [Double](repeating: 0, count: HeroState.count)
        delta[0] = dx; delta[1] = dy; delta[4] = dx; delta[5] = dy
        let arrived = min(max(1 - Self.distance(springs) / startDistance, 0), 1)
        springs.shift(delta, carried: arrived)
        return true
    }
}
