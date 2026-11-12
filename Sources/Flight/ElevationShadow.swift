#if canImport(UIKit)
import UIKit

/// The shadow of a picture as it flies: the one a thing at its height casts under a light from
/// above. The higher, the further down it falls, the softer and the fainter: a tight contact
/// shadow under it (strong low, gone high) and a wide soft one from the light. Its colour is the
/// image's own, darkened, as light through a coloured thing leaves; in the dark, near black (a
/// colour over black would be a glow), so it shows only where it falls on something lit.
///
/// Its height comes from its size: a thumbnail lying on its page (its `rest`, 4
/// for a picture lying on others) up to `high` full screen; it is seen as much as the page is,
/// fading over the backdrop.
///
/// Nothing is blurred while it moves: the shadow is drawn once per flight as two blurred
/// rounded rects of the thumbnail's shape (a sharp and a soft blur), and every frame only moves,
/// scales and fades them; the blur in between is the two cross-faded.
@MainActor
public final class ElevationShadow {
    /// The two blurs drawn, in the shape's own points.
    public static let sharp: CGFloat = 16, soft: CGFloat = 72
    /// Its height full screen, in points.
    public static let high: CGFloat = 44

    /// One of its two parts at height `e`: blur and drop in points, and opacity.
    public struct Part { public var blur: CGFloat; public var alpha: CGFloat; public var drop: CGFloat }
    public static func contact(_ e: CGFloat) -> Part { Part(blur: 16 + 0.5 * e, alpha: 0.07 * exp(-e / 14), drop: 3 + 0.2 * e) }
    public static func key(_ e: CGFloat) -> Part { Part(blur: 36 + 2.2 * e, alpha: 0.16 / (1 + e / 80), drop: 8 + 0.9 * e) }

    /// The shadow's colour for an image whose mean colour is `mean`: darkened and a little more
    /// saturated; near black in the dark, and stronger there (it shows only on what is lit).
    public static func color(mean: (r: CGFloat, g: CGFloat, b: CGFloat), dark: Bool) -> (color: CGColor, strength: CGFloat) {
        let grey = (mean.r + mean.g + mean.b) / 3, k: CGFloat = dark ? 0.1 : 0.6
        let c = [mean.r, mean.g, mean.b].map { min(max((grey + ($0 - grey) * 1.5) * k, 0), 1) }
        return (CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1), dark ? 1.8 : 1)
    }

    private static var means: [ObjectIdentifier: (r: CGFloat, g: CGFloat, b: CGFloat)] = [:]

    /// The mean colour of `image`: a small copy of it drawn into one pixel, kept for the image.
    public static func mean(of image: UIImage?) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let image else { return (0.5, 0.5, 0.5) }
        if let kept = means[ObjectIdentifier(image)] { return kept }
        let small = image.preparingThumbnail(of: CGSize(width: 16, height: 16)) ?? image
        let mean = drawnMean(small.cgImage)
        if means.count > 64 { means.removeAll() }
        means[ObjectIdentifier(image)] = mean
        return mean
    }

    private static func drawnMean(_ cg: CGImage?) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        guard let cg else { return (0.5, 0.5, 0.5) }
        var px = [UInt8](repeating: 0, count: 4)
        let drawn = px.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn, px[3] > 0 else { return (0.5, 0.5, 0.5) }
        let a = CGFloat(px[3])
        return (CGFloat(px[0]) / a, CGFloat(px[1]) / a, CGFloat(px[2]) / a)
    }

    private struct Sprite { let image: CGImage; let size: CGSize }

    /// The shape it was drawn for, its height at rest (nil: flat), and its size at rest and full screen.
    public let shape: CGSize
    public let rest: CGFloat?
    public let restDiagonal: CGFloat
    public let fullDiagonal: CGFloat
    private let strength: CGFloat
    private let sprites: [Sprite]
    /// Contact sharp, contact soft, key sharp, key soft.
    public let layers: [CALayer]

    /// - Parameters:
    ///   - shape: the thumbnail's size (the shadow's shape, scaled with the image as it grows).
    ///   - corner: its corner radius.
    ///   - rest: its height on the page, or nil if it lies flat (the shadow comes as it rises).
    ///   - full: the image's size full screen.
    public init(image: UIImage?, shape: CGSize, corner: CGFloat, rest: CGFloat?, full: CGSize, dark: Bool) {
        self.shape = shape
        self.rest = rest
        restDiagonal = hypot(shape.width, shape.height)
        fullDiagonal = hypot(full.width, full.height)
        let tint = Self.color(mean: Self.mean(of: image), dark: dark)
        strength = tint.strength
        // Blurred pixels need few of them: the sharp one at half a pixel a point, the soft at a quarter.
        let sprites = [(Self.sharp, 0.5), (Self.soft, 0.25)].map { blur, scale in
            Self.sprite(shape: shape, corner: corner, blur: blur, color: tint.color, scale: scale)
        }
        self.sprites = sprites
        layers = (0..<4).map { k in
            let layer = CALayer()
            let sprite = sprites[k % 2]
            layer.contents = sprite.image
            layer.bounds = CGRect(origin: .zero, size: sprite.size)
            layer.opacity = 0
            return layer
        }
    }

    private static func sprite(shape: CGSize, corner: CGFloat, blur: CGFloat, color: CGColor, scale: CGFloat) -> Sprite {
        let pad = ceil(blur * 1.5)
        let size = CGSize(width: shape.width + 2 * pad, height: shape.height + 2 * pad)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // The shape far off the image; only its shadow lands on it. The renderer's context
            // has its scale in its base space, so a shadow's offset and blur are in points here.
            let away: CGFloat = 10_000
            cg.setShadow(offset: CGSize(width: away, height: 0), blur: blur, color: color)
            cg.setFillColor(gray: 0, alpha: 1)
            cg.addPath(UIBezierPath(roundedRect: CGRect(x: pad - away, y: pad, width: shape.width, height: shape.height),
                                    cornerRadius: min(corner, min(shape.width, shape.height) / 2)).cgPath)
            cg.fillPath()
        }
        return Sprite(image: image.cgImage!, size: size)
    }

    /// Lays the shadow under a clip of `size` centred at `center`, turned by `turn`, `seen` of it.
    public func apply(center: CGPoint, size: CGSize, turn: CGFloat, seen: CGFloat) {
        let lift = min(max((hypot(size.width, size.height) - restDiagonal) / max(fullDiagonal - restDiagonal, 1e-3), 0), 1)
        let base = rest ?? 0
        let e = base + (Self.high - base) * lift
        // Flat at rest: it comes as it rises.
        let shown = max(seen, 0) * (rest == nil ? lift : 1) * strength
        let sx = size.width / max(shape.width, 1), sy = size.height / max(shape.height, 1)
        let s = sqrt(sx * sy)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (n, part) in [Self.contact(e), Self.key(e)].enumerated() {
            // The blur grows past the drawn ones by their stretching with the image; between them, a cross-fade.
            let t = min(max((part.blur / s - Self.sharp) / (Self.soft - Self.sharp), 0), 1)
            let transform = CATransform3DMakeAffineTransform(CGAffineTransform(rotationAngle: turn).scaledBy(x: sx, y: sy))
            // Down on the screen, whatever way it's turned.
            let position = CGPoint(x: center.x, y: center.y + part.drop)
            for (k, a) in [(2 * n, 1 - t), (2 * n + 1, t)] {
                let layer = layers[k]
                layer.position = position
                layer.transform = transform
                layer.opacity = Float(part.alpha * shown * a)
            }
        }
        CATransaction.commit()
    }
}
#endif
