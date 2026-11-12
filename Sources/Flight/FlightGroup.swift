#if canImport(UIKit)
import UIKit

/// Where a flying piece is: its middle, size, turn and corner radius, and any values of the
/// caller's own (an opacity, a shadow's height) springing along with them.
public struct FlightPlace: Equatable, Sendable {
    public var center: CGPoint
    public var size: CGSize
    public var turn: CGFloat
    public var corner: CGFloat
    public var extras: [Double]

    public init(center: CGPoint, size: CGSize, turn: CGFloat = 0, corner: CGFloat = 0, extras: [Double] = []) {
        self.center = center
        self.size = size
        self.turn = turn
        self.corner = corner
        self.extras = extras
    }

    public init(frame: CGRect, turn: CGFloat = 0, corner: CGFloat = 0, extras: [Double] = []) {
        self.init(center: CGPoint(x: frame.midX, y: frame.midY), size: frame.size, turn: turn, corner: corner, extras: extras)
    }

    public var frame: CGRect {
        CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    var vector: [Double] {
        [Double(center.x), Double(center.y), Double(size.width), Double(size.height), Double(turn), Double(corner)] + extras
    }

    init(_ v: [Double]) {
        center = CGPoint(x: v[0], y: v[1])
        size = CGSize(width: max(0, v[2]), height: max(0, v[3]))
        turn = CGFloat(v[4])
        corner = CGFloat(max(0, v[5]))
        extras = Array(v.dropFirst(6))
    }
}

/// One thing flying in a ``FlightGroup``: it springs from where it is to where `target` says,
/// asked every frame, so a target on content that scrolls is followed as it moves.
@MainActor
public final class FlightPiece {
    /// Where it is going, in the group's coordinates, read every frame; nil keeps the last.
    public var target: () -> FlightPlace?
    /// Puts it where it is now.
    public let apply: (FlightPlace) -> Void
    /// How long it waits before it sets off.
    public var delay: Double

    fileprivate var springs: SpringVector
    fileprivate var aim: FlightPlace
    fileprivate var startDistance: Double = 1
    fileprivate var waited: Double = 0
    fileprivate var landed = false

    /// - Parameters:
    ///   - from: where it starts.
    ///   - target: where it goes, read every frame.
    ///   - delay: seconds before it sets off.
    ///   - apply: puts it at a place; called every frame it moves.
    public init(from: FlightPlace, delay: Double = 0, target: @escaping () -> FlightPlace?, apply: @escaping (FlightPlace) -> Void) {
        self.target = target
        self.apply = apply
        self.delay = delay
        let values = from.vector
        let tolerances = [0.25, 0.25, 0.25, 0.25, 0.001, 0.1] + Array(repeating: 0.002, count: from.extras.count)
        springs = SpringVector(values: values, tolerances: tolerances, spring: .transition)
        aim = from
    }

    /// A view flying: placed by centre, bounds and turn, its layer's corners rounded. It never
    /// takes touches, so what lies under it can still be scrolled and tapped while it flies.
    public convenience init(view: UIView, from: FlightPlace, delay: Double = 0, target: @escaping () -> FlightPlace?,
                            extras: ((FlightPlace) -> Void)? = nil) {
        view.isUserInteractionEnabled = false
        self.init(from: from, delay: delay, target: target) { [weak view] place in
            guard let view else { return }
            view.bounds = CGRect(origin: .zero, size: place.size)
            view.center = place.center
            view.transform = place.turn == 0 ? .identity : CGAffineTransform(rotationAngle: place.turn)
            view.layer.cornerRadius = place.corner
            extras?(place)
        }
    }

    /// Where it is now.
    public var place: FlightPlace { FlightPlace(springs.values) }

    /// How far it has come, 0 at the start to 1 landed: what of a moving target it is carried with.
    public var arrived: Double {
        min(max(1 - Self.distance(springs) / startDistance, 0), 1)
    }

    fileprivate static func distance(_ springs: SpringVector) -> Double {
        (0..<4).reduce(0) { $0 + abs(springs.values[$1] - springs.targets[$1]) }
    }

    /// Sets off for `place` afresh: velocity kept, the way to go measured from here.
    fileprivate func aim(at place: FlightPlace, spring: FlightSpring) {
        aim = place
        springs.retarget(place.vector, spring: spring)
        startDistance = max(Self.distance(springs), 1)
        landed = false
    }

    /// Follows the target to `place`: a move (same size) carries it along by as much as it
    /// has arrived, so it neither lags behind the content nor swings after it, and lands
    /// exactly; anything else is a new aim.
    fileprivate func follow(_ place: FlightPlace, spring: FlightSpring) {
        guard place != aim else { return }
        let sameShape = abs(place.size.width - aim.size.width) < 0.5 && abs(place.size.height - aim.size.height) < 0.5
            && place.turn == aim.turn && place.corner == aim.corner && place.extras == aim.extras
        guard sameShape else {
            // Keep how far it has come: a new aim mid-way doesn't start the carrying over.
            let carried = arrived
            aim(at: place, spring: spring)
            startDistance = max(Self.distance(springs) / max(1 - carried, 0.05), 1)
            return
        }
        var delta = [Double](repeating: 0, count: springs.values.count)
        delta[0] = Double(place.center.x - aim.center.x)
        delta[1] = Double(place.center.y - aim.center.y)
        springs.shift(delta, carried: arrived)
        aim = place
        landed = false
    }
}

/// Things flying together, each springing to a target read every frame, as Messages' stack
/// flies its pictures into the grid: the targets may scroll while they fly, the flight may be
/// turned back mid-way (each keeps its speed), and nothing flying takes a touch, so the page
/// under it scrolls and taps as it would.
@MainActor
public final class FlightGroup {
    public private(set) var pieces: [FlightPiece]
    public var spring: FlightSpring
    /// Called once every piece is where it was going (again after each ``retarget(_:)``).
    public var onLanded: (() -> Void)?

    private lazy var clock = FlightClock { [weak self] dt in self?.step(dt) }

    public init(pieces: [FlightPiece], spring: FlightSpring = .transition) {
        self.pieces = pieces
        self.spring = spring
        for piece in pieces { piece.springs.spring = spring }
    }

    public var isFlying: Bool { clock.isRunning }

    /// Sets every piece off for its target.
    public func start() {
        for piece in pieces {
            piece.apply(piece.place)
            if let place = piece.target() { piece.aim(at: place, spring: spring) }
        }
        clock.start()
    }

    /// Turns the flight: each piece now goes where `targets` says for it (by its index; nil
    /// keeps its target), from where it is and at the speed it has.
    public func retarget(_ targets: (Int) -> (() -> FlightPlace?)?, spring: FlightSpring? = nil, delays: ((Int) -> Double)? = nil) {
        if let spring { self.spring = spring }
        for (i, piece) in pieces.enumerated() {
            if let target = targets(i) { piece.target = target }
            if let delays {
                piece.delay = delays(i)
                piece.waited = 0
            }
            if let place = piece.target() { piece.aim(at: place, spring: self.spring) }
        }
        clock.start()
    }

    /// Stops where everything is, without landing.
    public func stop() {
        clock.stop()
    }

    /// One frame, `dt` seconds after the last (the group's clock calls it; tests may too).
    func step(_ dt: Double) {
        var flying = false
        for piece in pieces {
            if let place = piece.target() { piece.follow(place, spring: spring) }
            if piece.waited < piece.delay {
                piece.waited += dt
                flying = true
                continue
            }
            if piece.landed { continue }
            piece.landed = piece.springs.step(dt)
            piece.apply(piece.place)
            if !piece.landed { flying = true }
        }
        if !flying {
            clock.stop()
            onLanded?()
        }
    }
}
#endif
