#if canImport(UIKit)
import UIKit

/// The layers of the page over a thumbnail, read off the view tree, and the image in flight put
/// among them: a sibling of the thumbnail or of one of its ancestors, coming after it (or standing
/// higher by `zPosition`), that draws something: a bar or a composer laid over the page, the next
/// picture of a group lying on this one, the cells after it.
///
/// The image in flight really goes there: under a layer it is a subview of that layer's parent,
/// just below it, so the layer draws over it as it draws over the thumbnail (a bar's glass blurs
/// it); over everything it is back on the viewer's stage. It changes place only when none of the
/// layer it passes lies on it, so that is never seen.
@MainActor
final class PreviewLayers {
    private struct Layer {
        weak var view: UIView?
        weak var parent: UIView?
        /// The thumbnail's ancestor in the same parent (or the thumbnail).
        weak var under: UIView?
        /// What of it draws, whose frames are its shapes.
        var parts: [WeakView]
        let paged: Bool
    }
    private struct WeakView { weak var view: UIView? }

    private let layers: [Layer]
    private weak var thumbnail: UIView?
    private weak var stage: UIView?

    var count: Int { layers.count }

    /// - Parameters:
    ///   - thumbnail: the thumbnail's view.
    ///   - stage: the viewer's stage, where the image flies when over everything.
    init(thumbnail: UIView, stage: UIView) {
        self.thumbnail = thumbnail
        self.stage = stage
        var layers: [Layer] = []
        guard let window = thumbnail.window else {
            self.layers = []
            return
        }
        let scroller = Self.scrollView(around: thumbnail)
        var child = thumbnail
        while let parent = child.superview {
            let siblings = parent.subviews
            let index = siblings.firstIndex(of: child) ?? 0
            let height = child.layer.zPosition
            var above: [(UIView, Int)] = []
            for (i, sibling) in siblings.enumerated() where sibling !== child {
                let z = sibling.layer.zPosition
                guard z > height || (z == height && i > index) else { continue }
                if stage.isDescendant(of: sibling) || sibling.isDescendant(of: stage) { continue }
                above.append((sibling, i))
            }
            // Lowest first: by zPosition, then by order.
            above.sort { ($0.0.layer.zPosition, $0.1) < ($1.0.layer.zPosition, $1.1) }
            for (sibling, _) in above {
                var parts: [UIView] = []
                Self.collectParts(of: sibling, in: window, into: &parts)
                guard !parts.isEmpty else { continue }
                if parts.count > 24 { parts = [sibling] }
                layers.append(Layer(view: sibling, parent: parent, under: child, parts: parts.map { WeakView(view: $0) },
                                    paged: scroller.map { sibling.isDescendant(of: $0) } ?? false))
            }
            if parent === window { break }
            child = parent
        }
        self.layers = layers
    }

    /// The scroll view the thumbnail scrolls with, if any.
    private static func scrollView(around view: UIView) -> UIScrollView? {
        var next = view.superview
        while let current = next {
            if let scroll = current as? UIScrollView { return scroll }
            next = current.superview
        }
        return nil
    }

    /// The views in `view` that draw something on screen: a colour, contents, a material.
    private static func collectParts(of view: UIView, in window: UIWindow, into parts: inout [UIView]) {
        guard !view.isHidden, view.alpha > 0.01, !isScrollChrome(view), parts.count <= 24 else { return }
        let frame = view.convert(view.bounds, to: window)
        if view.clipsToBounds, !frame.intersects(window.bounds) { return }
        if draws(view) {
            if frame.intersects(window.bounds) { parts.append(view) }
            if view is UIVisualEffectView { return }
        }
        for sub in view.subviews { collectParts(of: sub, in: window, into: &parts) }
    }

    private static func draws(_ view: UIView) -> Bool {
        if view is UIVisualEffectView { return true }
        let layer = view.layer
        if layer.contents != nil { return true }
        if let color = layer.backgroundColor, color.alpha > 0.05 { return true }
        if layer.borderWidth > 0 || (layer.shadowOpacity > 0 && layer.shadowPath != nil) { return true }
        return view is UILabel || view is UIImageView && (view as? UIImageView)?.image != nil
    }

    /// A scroll view's own bits: its indicators and the soft edge under its bars, which blur what
    /// goes under them rather than hide it.
    private static func isScrollChrome(_ view: UIView) -> Bool {
        let name = NSStringFromClass(type(of: view))
        return name.contains("ScrollIndicator") || name.contains("Pocket") || name.contains("EdgeEffect")
    }

    // MARK: Shapes

    /// Each layer's shapes now, in the stage.
    func shapes() -> [[TurnedRect]] {
        guard let stage else { return layers.map { _ in [] } }
        return layers.map { layer in layer.parts.compactMap { $0.view.flatMap { Self.turnedFrame(of: $0, in: stage) } } }
    }

    var paged: [Bool] { layers.map(\.paged) }

    /// Where `view` is in `space`: its centre, its size there and how it's turned.
    static func turnedFrame(of view: UIView, in space: UIView) -> TurnedRect? {
        guard view.window != nil, space.window != nil else { return nil }
        let b = view.bounds
        let o = view.convert(CGPoint(x: b.minX, y: b.minY), to: space)
        let x = view.convert(CGPoint(x: b.maxX, y: b.minY), to: space)
        let y = view.convert(CGPoint(x: b.minX, y: b.maxY), to: space)
        let c = view.convert(CGPoint(x: b.midX, y: b.midY), to: space)
        let w = hypot(x.x - o.x, x.y - o.y), h = hypot(y.x - o.x, y.y - o.y)
        guard w > 0.5, h > 0.5 else { return nil }
        return TurnedRect(center: c, size: CGSize(width: w, height: h), turn: atan2(x.y - o.y, x.x - o.x))
    }

    // MARK: Hosting

    /// Puts `hero` where an image over `level` of the layers is drawn: under the next layer up
    /// and over all the ones before it; over all of them, on the stage. Its own coordinates stay
    /// the stage's, wherever it is (`place`).
    ///
    /// Under a layer whose parent has none of the passed ones, it goes last into the thumbnail's
    /// own ancestor there: drawn with it, over all it holds, so it stays right however that
    /// parent orders its subviews (a collection view sorts its cells). Else (passed layers there,
    /// or that ancestor is the hidden thumbnail itself, or clips) it goes into the parent just
    /// over the highest layer passed, or over the thumbnail's ancestor.
    func host(_ hero: UIView, level: Int) {
        guard let stage else { return }
        var level = level
        // A layer gone from the screen (its cell reused): the next one up.
        while level < layers.count, layers[level].view?.window == nil || layers[level].parent?.window == nil { level += 1 }
        if level >= layers.count {
            hero.layer.zPosition = 0
            if hero.superview !== stage || stage.subviews.last !== hero { stage.addSubview(hero) }
            return place(hero)
        }
        let layer = layers[level]
        guard let parent = layer.parent else { return }
        let passed = layers[..<level].filter { $0.parent === parent }.compactMap(\.view)
        if passed.isEmpty, let ancestor = layer.under, ancestor !== thumbnail, !ancestor.isHidden, ancestor.alpha > 0.01,
           !ancestor.clipsToBounds, !ancestor.layer.masksToBounds, ancestor.window != nil {
            let others = ancestor.subviews.filter { $0 !== hero }
            hero.layer.zPosition = others.map(\.layer.zPosition).max() ?? 0
            if hero.superview !== ancestor || ancestor.subviews.last !== hero { ancestor.addSubview(hero) }
        } else if let top = passed.last ?? layer.under {
            hero.layer.zPosition = top.layer.zPosition
            let siblings = parent.subviews
            if hero.superview !== parent || siblings.firstIndex(of: hero) != (siblings.firstIndex(of: top) ?? 0) + 1 {
                parent.insertSubview(hero, aboveSubview: top)
            }
        } else if let cover = layer.view {
            hero.layer.zPosition = cover.layer.zPosition
            if hero.superview !== parent { parent.insertSubview(hero, belowSubview: cover) }
        }
        place(hero)
    }

    /// Lays `hero` out so that its coordinates are the stage's, wherever it is.
    func place(_ hero: UIView) {
        guard let stage, let host = hero.superview else { return }
        hero.bounds = stage.bounds
        guard host !== stage else {
            hero.transform = .identity
            hero.center = CGPoint(x: stage.bounds.midX, y: stage.bounds.midY)
            return
        }
        let o = stage.convert(CGPoint.zero, to: host)
        let x = stage.convert(CGPoint(x: 1, y: 0), to: host)
        let y = stage.convert(CGPoint(x: 0, y: 1), to: host)
        hero.transform = CGAffineTransform(a: x.x - o.x, b: x.y - o.y, c: y.x - o.x, d: y.y - o.y, tx: 0, ty: 0)
        hero.center = stage.convert(CGPoint(x: stage.bounds.midX, y: stage.bounds.midY), to: host)
    }
}
#endif
