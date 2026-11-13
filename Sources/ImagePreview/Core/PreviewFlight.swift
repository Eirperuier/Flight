import CoreGraphics
import Foundation

// The flight between a thumbnail and full screen when things are drawn over the thumbnail (a bar,
// a composer, the next picture of a group lying on it).
//
// One point and one velocity, as Heads' faces: a critically damped spring pulls the image toward a
// goal. The goal never jumps: it eases from one aim to the next, and each aim is read off the page
// on every frame, so when the page moves the goal moves with it and nothing is planned again.
// Changing layer is not a step of the motion: it happens on the frame the image and that layer stop
// touching, wherever the spring has carried it by then, so no layer ever pops over or under it.
//
// Opening: still under what lies on it, the image slides out (in the page) and rises over each
// layer the moment it's clear of it; the place and the size are one spring, so it grows as it goes.
// Closing: it keeps the finger's velocity; if something lies on its place it goes by the way out,
// outermost spot first, drops under each layer there, clear of it, and slides in under them.
// How the way out goes (one slide or layer by layer, how far it leans toward where it goes next,
// how much it may grow on it) and when the goal bends on toward the next aim are found by
// rehearsing the flight ahead: the earliest bend that still comes out clear, the way that is
// quickest with the least dip in speed.

/// A rect turned about its centre.
struct TurnedRect: Equatable {
    var center: CGPoint
    var size: CGSize
    var turn: CGFloat

    init(center: CGPoint, size: CGSize, turn: CGFloat = 0) {
        self.center = center
        self.size = size
        self.turn = turn
    }

    init(_ rect: CGRect) {
        self.init(center: CGPoint(x: rect.midX, y: rect.midY), size: rect.size)
    }

    func moved(_ d: CGVector) -> TurnedRect {
        TurnedRect(center: CGPoint(x: center.x + d.dx, y: center.y + d.dy), size: size, turn: turn)
    }

    func at(_ point: CGPoint) -> TurnedRect { TurnedRect(center: point, size: size, turn: turn) }

    var corners: [CGPoint] {
        let c = cos(turn), s = sin(turn), w = size.width / 2, h = size.height / 2
        return [(-w, -h), (w, -h), (w, h), (-w, h)].map { CGPoint(x: center.x + $0.0 * c - $0.1 * s, y: center.y + $0.0 * s + $0.1 * c) }
    }

    /// Its extent along the unit vector `(nx, ny)`, its own turn's cosine and sine being `c` and `s`.
    @inline(__always)
    private func shadow(_ nx: CGFloat, _ ny: CGFloat, _ c: CGFloat, _ s: CGFloat) -> (CGFloat, CGFloat) {
        let half = abs(size.width / 2 * (c * nx + s * ny)) + abs(size.height / 2 * (-s * nx + c * ny))
        let m = center.x * nx + center.y * ny
        return (m - half, m + half)
    }

    /// How far this has to move along `u` (a unit vector) to be clear of `other`: 0 if it is,
    /// infinity if it never gets clear that way. Closed form (separating axes). Run every
    /// frame of every rehearsal: no allocation, and far apart is settled first.
    func clearance(from other: TurnedRect, along u: CGVector) -> CGFloat {
        let reach = (hypot(size.width, size.height) + hypot(other.size.width, other.size.height)) / 2
        let dx = center.x - other.center.x, dy = center.y - other.center.y
        if dx * dx + dy * dy >= reach * reach { return 0 }
        let c1 = cos(turn), s1 = sin(turn), c2 = cos(other.turn), s2 = sin(other.turn)
        var best = CGFloat.infinity
        for axis in 0..<4 {
            let nx: CGFloat, ny: CGFloat
            switch axis {
            case 0: nx = c1; ny = s1
            case 1: nx = -s1; ny = c1
            case 2: nx = c2; ny = s2
            default: nx = -s2; ny = c2
            }
            let (a0, a1) = shadow(nx, ny, c1, s1), (b0, b1) = other.shadow(nx, ny, c2, s2), k = u.dx * nx + u.dy * ny
            if a1 <= b0 || a0 >= b1 { return 0 }
            if k > 1e-6 { best = min(best, (b1 - a0) / k) } else if k < -1e-6 { best = min(best, (b0 - a1) / k) }
        }
        return best
    }

    func overlaps(_ other: TurnedRect) -> Bool { clearance(from: other, along: CGVector(dx: 1, dy: 0)) > 0 }

    /// How far its corners stick out of `bounds`.
    func outside(_ bounds: CGRect) -> CGFloat {
        corners.reduce(0) { max($0, bounds.minX - $1.x, $1.x - bounds.maxX, bounds.minY - $1.y, $1.y - bounds.maxY) }
    }
}

/// What a flight sees on one frame, in the viewer's coordinates.
struct FlightWorld {
    /// The thumbnail's visible part (the clip of its state), turned as it is.
    var slot: TurnedRect
    /// What's drawn over the thumbnail, lowest first: each layer's shapes.
    var covers: [[TurnedRect]]
    /// Whether each layer moves with the page (the thumbnail's scroll view).
    var paged: [Bool]
    /// The image fitted full screen.
    var fitted: CGRect
    var bounds: CGRect

    /// As it will be once the page has moved by `d`.
    func shifted(_ d: CGVector) -> FlightWorld {
        guard d.dx != 0 || d.dy != 0 else { return self }
        var world = self
        world.slot = slot.moved(d)
        world.covers = covers.indices.map { paged[$0] ? covers[$0].map { $0.moved(d) } : covers[$0] }
        return world
    }

    func clear(_ q: TurnedRect, of layer: Int) -> Bool { !covers[layer].contains { q.overlaps($0) } }

    func clearance(_ q: TurnedRect, from layers: [Int], along u: CGVector) -> CGFloat {
        var d: CGFloat = 0
        for layer in layers { for shape in covers[layer] { d = max(d, q.clearance(from: shape, along: u)) } }
        return d
    }

    func overlapping(_ q: TurnedRect, _ layers: [Int]) -> Bool { layers.contains { !clear(q, of: $0) } }
}

struct PreviewFlight {
    enum Kind { case opening, closing }

    /// Opening: one spring for place and size, ω `openOmega`; stiffer (`escapeOmega`) while it
    /// comes out from under the layers, easing back over `lift` once over them all, so it
    /// starts briskly and no force jumps.
    static let openOmega = 20.0, escapeOmega = 30.0
    /// Closing: the viewer's own closing spring (`ImagePreviewConfiguration.transitionSpring`),
    /// for the place and the size alike, as a close with nothing over the thumbnail has it.
    static let homeOmega = 2 * Double.pi / PreviewSpring.transition.response, homeZeta = PreviewSpring.transition.dampingRatio
    /// The goal eases in from rest over `emerge` (barely: it starts at once), and from one aim to
    /// the next over `lift`.
    static let emerge = 0.05, lift = 0.25
    static let step = 1.0 / 240

    let kind: Kind
    private(set) var center: CGPoint
    private(set) var velocity: CGVector
    /// How far it has gone from where it started to where it ends: opening 0 the thumbnail, 1
    /// full screen; closing 0 as it was let go, 1 the thumbnail.
    private(set) var progress: Double = 0
    private var progressVelocity: Double = 0
    /// How many of the layers over the thumbnail it is over, lowest first.
    private(set) var level: Int
    let layerCount: Int
    private(set) var clock: Double = 0
    private(set) var isDone = false
    /// Ended without getting clear of a layer (it shouldn't): it dropped under it (closing) or
    /// went over it (opening) anyway.
    private(set) var landedUncleared = false
    /// How much it moves with the page now: as much as its goal does.
    private var attach: Double = 1
    /// Opening: its progress, and the time, when it got over everything (the backdrop starts from there).
    private var overAt: Double?
    private var overClock: Double?
    /// Closing: the spring home, ω and damping ratio.
    private var home = (omega: Self.homeOmega, zeta: Self.homeZeta)
    /// Closing: how long it has been waiting, still, under a layer it can't get clear of.
    private var stuck: Double = 0
    /// Closing: the clip's size and the backdrop as it was let go.
    private let releaseSize: CGSize
    private let releaseBackdrop: CGFloat
    private var lastSlot: CGPoint
    private var pageMoves: [(t: Double, d: CGVector)] = []
    private var plan: Plan
    private var goal: [Leg] = []
    private var rehearsing = false
    private var lastSeen: (half: CGFloat, speed: Double)?
    /// The way-out spots, as read off the page for the slot where it was (read again when it moves).
    private var spotsRead: (slot: TurnedRect, at: [CGPoint])?
    /// Every layer change so far, for whoever wants to check them: (time, from level, to level).
    private(set) var changes: [(t: Double, from: Int, to: Int)] = []

    // MARK: Starting

    /// Opening from the thumbnail at rest; or, given `from`, from an image flying home (a clip of
    /// that size at that centre, that velocity, over `level` of the layers), turned back.
    /// - Parameter planned: chosen ahead now; else it goes straight for the middle until a plan
    ///   chosen elsewhere is handed to it (`adoptPlan`).
    static func opening(_ world: FlightWorld, from: (center: CGPoint, size: CGSize, velocity: CGVector, level: Int)? = nil, planned: Bool = true) -> PreviewFlight {
        var flight = PreviewFlight(kind: .opening, center: from?.center ?? world.slot.center, velocity: from?.velocity ?? .zero, world: world,
                                   releaseSize: world.slot.size, releaseBackdrop: 0)
        if let from {
            let s = world.slot.size, f = world.fitted.size
            let g = max(f.width - s.width, f.height - s.height) > 1
                ? Double((hypot(from.size.width, from.size.height) - hypot(s.width, s.height)) / (hypot(f.width, f.height) - hypot(s.width, s.height)))
                : 0
            flight.progress = min(max(g, 0), 1)
            flight.level = min(max(from.level, 0), world.covers.count)
        }
        if planned { flight.choosePlan(world, pageVelocity: .zero) } else { flight.startStraight(world) }
        return flight
    }

    /// Closing into the thumbnail, from a clip of `size` at `center` moving at `velocity` with
    /// the backdrop at `backdrop`, on the spring `omega`, `zeta`.
    static func closing(_ world: FlightWorld, center: CGPoint, size: CGSize, velocity: CGVector, backdrop: CGFloat, pageVelocity: CGVector = .zero,
                        omega: Double = homeOmega, zeta: Double = homeZeta, planned: Bool = true) -> PreviewFlight {
        var flight = PreviewFlight(kind: .closing, center: center, velocity: velocity, world: world, releaseSize: size, releaseBackdrop: backdrop)
        flight.home = (omega, zeta)
        if planned { flight.choosePlan(world, pageVelocity: pageVelocity) } else { flight.startStraight(world) }
        return flight
    }

    /// The finger's velocity as the image keeps it when let go, as a close with nothing over the
    /// thumbnail has it: all of it toward home, a third of the rest; capped.
    static func released(_ v: CGVector, from: CGPoint, toward home: CGPoint) -> CGVector {
        let distance = hypot(home.x - from.x, home.y - from.y)
        var out = CGVector(dx: v.dx * 0.3, dy: v.dy * 0.3)
        if distance > 1 {
            let d = CGVector(dx: (home.x - from.x) / distance, dy: (home.y - from.y) / distance)
            let along = v.dx * d.dx + v.dy * d.dy
            if along > 0 {
                out = CGVector(dx: d.dx * along + (v.dx - d.dx * along) * 0.3, dy: d.dy * along + (v.dy - d.dy * along) * 0.3)
            }
        }
        let speed = hypot(out.dx, out.dy), cap: CGFloat = 2500
        if speed > cap { out = CGVector(dx: out.dx * cap / speed, dy: out.dy * cap / speed) }
        return out
    }

    /// Till a plan comes (`adoptPlan`): opening, it waits where it is (it was planned from there,
    /// so it goes on just as planned); closing, straight home with the finger's velocity. An
    /// opening with nothing over it goes straight for the middle after a while if none comes;
    /// under a layer it waits for its way out however long that takes, as grown into the layer
    /// on the way to the middle it could never get over it.
    private mutating func startStraight(_ world: FlightWorld) {
        if kind == .opening { changeLayers(world, clip(world)); changes = [] }
        setPlan(world, stages: [], margin: Self.margins[0], grow: 0, times: nil)
        if kind == .opening {
            goal = [Leg(aim: .fixed(center, 1, progress), t0: clock, duration: 0)]
            if isOverAll { goal.append(Leg(aim: .centre, t0: clock + Self.planWait, duration: Self.emerge)) }
        }
    }

    /// How long an opening with nothing over it waits for its plan before going without one.
    static let planWait = 0.3

    /// This flight as it will be `delay` on, with its plan chosen there: made off the main
    /// thread while this one flies on unplanned, and put in its place when it gets there (it is
    /// the same flight till then, so nothing shows).
    func plannedAhead(by delay: Double, world: FlightWorld, pageVelocity v: CGVector = .zero) -> PreviewFlight {
        var copy = self
        var left = delay
        while left > 1e-9 {
            let h = min(left, 0.05)
            left -= h
            copy.advance(h, world: world.shifted(CGVector(dx: v.dx * (delay - left), dy: v.dy * (delay - left))))
        }
        copy.choosePlan(world.shifted(CGVector(dx: v.dx * delay, dy: v.dy * delay)), pageVelocity: v)
        return copy
    }

    /// Takes the plan `other` chose (the same flight, planned elsewhere from the same start):
    /// its goal from now on, eased in from the one so far.
    mutating func adoptPlan(of other: PreviewFlight, world: FlightWorld) {
        let from = goalValue(world)
        plan = other.plan
        // Its bend times counted from when it was chosen: from now, as its goal starts now.
        plan.times = plan.times.map { $0 + (clock - other.clock) }
        plan.next = 0
        plan.fired = Array(repeating: nil, count: plan.events.count)
        spotsRead = nil
        // From where the goal is, easing into the plan's first aim, so no force jumps.
        goal = [Leg(aim: .fixed(from.point, from.w, from.g), t0: clock, duration: 0), Leg(aim: plan.aims[0], t0: clock, duration: Self.emerge)]
        // Events already done on the way here.
        bend(world)
    }

    private init(kind: Kind, center: CGPoint, velocity: CGVector, world: FlightWorld, releaseSize: CGSize, releaseBackdrop: CGFloat) {
        self.kind = kind
        self.center = center
        self.velocity = velocity
        self.layerCount = world.covers.count
        self.level = kind == .opening ? 0 : world.covers.count
        self.releaseSize = releaseSize
        self.releaseBackdrop = releaseBackdrop
        self.lastSlot = world.slot.center
        self.plan = Plan(aims: [kind == .opening ? .centre : .slot], stages: [], events: [], margin: Self.margins[0], grow: 0)
    }

    // MARK: What it looks like

    /// Its clip now, turned as it is.
    func clip(_ world: FlightWorld) -> TurnedRect {
        let g = CGFloat(progress)
        switch kind {
        case .opening:
            let s = world.slot.size, f = world.fitted.size
            return TurnedRect(center: center, size: CGSize(width: s.width + (f.width - s.width) * g, height: s.height + (f.height - s.height) * g), turn: world.slot.turn * (1 - g))
        case .closing:
            let s = releaseSize, t = world.slot.size
            return TurnedRect(center: center, size: CGSize(width: s.width + (t.width - s.width) * g, height: s.height + (t.height - s.height) * g), turn: world.slot.turn * g)
        }
    }

    /// How dark the backdrop is now.
    var backdrop: CGFloat {
        switch kind {
        case .opening:
            if isDone { return 1 }
            guard let overAt else { return 0 }
            return CGFloat(min(max((progress - overAt) / max(1 - overAt, 1e-3), 0), 1))
        case .closing:
            return releaseBackdrop * CGFloat(1 - Self.ease(progress / 0.7))
        }
    }

    var isOverAll: Bool { level >= layerCount }

    /// How fast it looks to move: its centre, plus how fast its edges grow or shrink.
    private(set) var seenSpeed: Double = 0

    // MARK: Stepping

    /// Advances by `dt` on the page as it is now.
    mutating func advance(_ dt: Double, world: FlightWorld) {
        // The page moved under it: opening, it moves with it as much as its goal does; closing,
        // all the way, as the page's own: it's going home into the page, and its way there (round
        // what lies on its place) is the page's too. Carried by less, it lags the page and drifts
        // off its way, waiting by a layer for the place the page has taken elsewhere.
        let d = CGVector(dx: world.slot.center.x - lastSlot.x, dy: world.slot.center.y - lastSlot.y)
        lastSlot = world.slot.center
        if d.dx != 0 || d.dy != 0 {
            let carried = kind == .closing ? 1 : attach
            center.x += d.dx * carried
            center.y += d.dy * carried
            plan.moved += hypot(d.dx, d.dy)
            pageMoves.append((clock, d))
        }
        var left = min(dt, 0.1)
        while left > 1e-9, !isDone {
            let h = min(Self.step, left)
            left -= h
            tick(h, world)
        }
    }

    /// The page's velocity now (over the last tenth of a second).
    mutating func pageVelocity() -> CGVector {
        pageMoves.removeAll { clock - $0.t > 0.1 }
        guard pageMoves.count > 1, let first = pageMoves.first else { return .zero }
        let span = max(clock - first.t, 1.0 / 60)
        let sum = pageMoves.reduce(CGVector.zero) { CGVector(dx: $0.dx + $1.d.dx, dy: $0.dy + $1.d.dy) }
        return CGVector(dx: sum.dx / span, dy: sum.dy / span)
    }

    private mutating func tick(_ h: Double, _ world: FlightWorld) {
        clock += h
        let target = goalValue(world)
        attach = target.w
        switch kind {
        case .opening:
            let eased = overClock.map { Self.ease((clock - $0) / Self.lift) } ?? 0
            let w = plan.stages.isEmpty ? Self.openOmega : Self.escapeOmega + (Self.openOmega - Self.escapeOmega) * eased
            velocity.dx += (w * w * (target.point.x - center.x) - 2 * w * velocity.dx) * h
            velocity.dy += (w * w * (target.point.y - center.y) - 2 * w * velocity.dy) * h
            progressVelocity += (w * w * (target.g - progress) - 2 * w * progressVelocity) * h
        case .closing:
            let w = home.omega, z = home.zeta
            velocity.dx += (w * w * (target.point.x - center.x) - 2 * z * w * velocity.dx) * h
            velocity.dy += (w * w * (target.point.y - center.y) - 2 * z * w * velocity.dy) * h
            // Its size goes home on the same spring from the moment it's let go.
            progressVelocity += (w * w * (1 - progress) - 2 * z * w * progressVelocity) * h
        }
        center.x += velocity.dx * h
        center.y += velocity.dy * h
        progress += progressVelocity * h
        let q = clip(world)
        let half = hypot(q.size.width, q.size.height) / 2
        seenSpeed = hypot(velocity.dx, velocity.dy) + (lastSeen.map { abs(half - $0.half) / h } ?? 0)
        lastSeen = (half, seenSpeed)
        if kind == .closing { attach = progress }
        changeLayers(world, q)
        bend(world)
        if replanIfStuck(world, h) { return }
        finishIfThere(world)
    }

    /// Closing: waiting, still, under a layer it can't get clear of where its goal is (the page
    /// moved it somewhere its way out no longer works): planned afresh from where it is, as it's
    /// moving, its size and layer as they are.
    private mutating func replanIfStuck(_ world: FlightWorld, _ h: Double) -> Bool {
        guard kind == .closing, !rehearsing else { return false }
        stuck = level > 0 && backdrop < 0.02 && hypot(velocity.dx, velocity.dy) < 8 ? stuck + h : 0
        guard stuck > 0.15 else { return false }
        stuck = 0
        choosePlan(world, pageVelocity: pageVelocity())
        return true
    }

    private mutating func changeLayers(_ world: FlightWorld, _ q: TurnedRect) {
        let was = level
        switch kind {
        case .opening:
            // Over each layer in turn, lowest first, as soon as none of it lies on the image.
            while level < layerCount, world.clear(q, of: level) { level += 1 }
            if level >= layerCount, overAt == nil { overAt = progress; overClock = clock }
        case .closing:
            // Under each layer, highest first, the moment none of it lies on the image, once the dark is gone.
            guard backdrop < 0.02 else { return }
            while level > 0, world.clear(q, of: level - 1) { level -= 1 }
        }
        if level != was { changes.append((clock, was, level)) }
    }

    private mutating func finishIfThere(_ world: FlightWorld) {
        guard plan.next == plan.events.count else { return }
        let aim = kind == .opening ? CGPoint(x: world.fitted.midX, y: world.fitted.midY) : world.slot.center
        let near = hypot(center.x - aim.x, center.y - aim.y), speed = hypot(velocity.dx, velocity.dy)
        let grown = abs(1 - progress) < 1e-3 && abs(progressVelocity) < 0.01
        switch kind {
        case .opening:
            if isOverAll, grown, near < 0.3, speed < 4 { isDone = true }
            // Grew into a layer it never got over (it shouldn't; the page moved a layer onto it):
            // over it anyway, rather than left under it.
            else if clock > 1.9, grown, near < 2 { level = layerCount; isDone = true; landedUncleared = true }
        case .closing:
            if level == 0, clock > Self.lift, grown, near < 0.3, speed < 4 { isDone = true }
            // Never got clear (it should): land anyway.
            else if clock > 1.9, grown, near < 2 { level = 0; isDone = true; landedUncleared = true }
        }
        if isDone {
            center = aim
            velocity = .zero
            progress = 1
        }
    }

    static func ease(_ u: Double) -> Double { u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u) }

    // MARK: Aims and the goal

    enum Aim: Equatable { case slot, spot(Int), centre, fixed(CGPoint, Double, Double) }

    /// The plan: the aims in the order it goes by them, the way-out stages (outward from the
    /// thumbnail) the spots are read from, and the event that ends each aim but the last.
    struct Plan {
        var aims: [Aim]
        var stages: [(layers: [Int], dir: CGVector)]
        var events: [Event]
        var margin: Margin
        var grow: Double
        var times: [Double] = []
        var next = 0
        var fired: [Double?] = []
        var moved: Double = 0
        var checkedAt: Double = 0
    }
    enum Event { case over(Int), under(Int) }
    struct Margin { var k: CGFloat; var add: CGFloat }
    static let margins = [Margin(k: 1.15, add: 8), Margin(k: 1.5, add: 14)]
    static let grows = [0.0, 0.2]
    static let leans: [CGFloat] = [0.3, 4]

    private struct Leg { var aim: Aim; var t0: Double; var duration: Double }
    // (A leg starting later holds the goal where the legs before it have it till then.)

    private mutating func aimValue(_ aim: Aim, _ world: FlightWorld) -> (point: CGPoint, w: Double, g: Double) {
        switch aim {
        case .slot: return (world.slot.center, 1, kind == .opening ? 0 : 1)
        case .centre: return (CGPoint(x: world.fitted.midX, y: world.fitted.midY), 0, 1)
        case .fixed(let point, let w, let g): return (point, w, g)
        case .spot(let k):
            // Each spot read from the last, where the page has it now; the same while the slot
            // stays where it is (a rehearsal on a still page reads them once).
            if spotsRead?.slot != world.slot || (spotsRead?.at.count ?? 0) != plan.stages.count {
                var base = world.slot.center, at: [CGPoint] = []
                for stage in plan.stages {
                    let d = world.clearance(world.slot.at(base), from: stage.layers, along: stage.dir) * plan.margin.k + plan.margin.add
                    base = CGPoint(x: base.x + stage.dir.dx * d, y: base.y + stage.dir.dy * d)
                    at.append(base)
                }
                spotsRead = (world.slot, at)
            }
            return (spotsRead!.at[k], 1, kind == .opening ? plan.grow : 0)
        }
    }

    /// The goal: each leg eases from what the legs before it gave to its own aim.
    private mutating func goalValue(_ world: FlightWorld) -> (point: CGPoint, w: Double, g: Double) {
        if let done = goal.lastIndex(where: { clock - $0.t0 >= $0.duration }), done > 0 { goal.removeFirst(done) }
        var value = aimValue(goal[0].aim, world)
        for leg in goal.dropFirst() {
            let u = Self.ease((clock - leg.t0) / leg.duration), b = aimValue(leg.aim, world)
            value = (CGPoint(x: value.point.x + (b.point.x - value.point.x) * u, y: value.point.y + (b.point.y - value.point.y) * u),
                     value.w + (b.w - value.w) * u, value.g + (b.g - value.g) * u)
        }
        return value
    }

    private mutating func aim(at aim: Aim, over duration: Double) {
        goal.append(Leg(aim: aim, t0: clock, duration: duration))
    }

    private func eventFired(_ e: Event) -> Bool {
        switch e {
        case .over(let top): level > top
        case .under(let low): level <= low
        }
    }

    // MARK: Bending

    /// On to the next aim when the layers it was for are done, or at the time set for it ahead,
    /// whichever comes first: set early, the goal bends toward the next aim before the image gets
    /// to the last, so it never slows down to arrive anywhere but where it ends. The time was
    /// found with the page as it was moving then; if it has moved since, the bend is tried again
    /// first, and kept only if the layers don't have to wait longer for it.
    private mutating func bend(_ world: FlightWorld) {
        if !rehearsing, plan.next > 0, plan.moved > plan.checkedAt + 4, !eventFired(plan.events[plan.next - 1]) {
            plan.checkedAt = plan.moved
            let j = plan.next - 1
            var back = self
            back.plan.times[j] = .infinity
            back.plan.next = j
            back.aim(at: plan.aims[j], over: Self.lift)
            if layersDone(world) > back.layersDone(world) + 0.03 { self = back }
        }
        while plan.next < plan.events.count {
            let j = plan.next
            if eventFired(plan.events[j]) {
                if plan.fired[j] == nil { plan.fired[j] = clock }
            } else if clock >= plan.times[j] {
                var now = self, wait = self
                now.plan.times[j] = clock
                wait.plan.times[j] = .infinity
                if !rehearsing, plan.moved > 0, now.bendingNow(world) > wait.layersDone(world) + 0.03 {
                    plan.times[j] = .infinity
                    break
                }
            } else { break }
            aim(at: plan.aims[j + 1], over: Self.lift)
            plan.next += 1
        }
    }

    private func bendingNow(_ world: FlightWorld) -> Double {
        var copy = self
        copy.aim(at: plan.aims[plan.next + 1], over: Self.lift)
        copy.plan.next += 1
        return copy.layersDone(world)
    }

    /// When, rehearsing on from here, it's over every layer (opening) or under all of them (closing).
    private func layersDone(_ world: FlightWorld) -> Double {
        var copy = self
        let v = copy.pageVelocity()
        let r = copy.rehearse(world, pageVelocity: v) { $0.kind == .opening ? $0.isOverAll : $0.level == 0 }
        return r.ok ? r.time : .infinity
    }

    // MARK: Rehearsing

    private struct Rehearsal { var ok: Bool; var time: Double; var dip: Double; var fired: [Double?] }

    private func rehearse(_ world: FlightWorld, pageVelocity v: CGVector, limit: Double = 3, until: (PreviewFlight) -> Bool) -> Rehearsal {
        var copy = self
        copy.rehearsing = true
        var speeds: [Double] = []
        speeds.reserveCapacity(Int(limit / Self.step))
        let start = clock
        var ok = false
        while copy.clock - start < limit {
            let t = copy.clock - start + Self.step
            copy.advance(Self.step, world: world.shifted(CGVector(dx: v.dx * t, dy: v.dy * t)))
            speeds.append(copy.seenSpeed)
            if until(copy) { ok = true; break }
            if copy.isDone { break }
        }
        return Rehearsal(ok: ok, time: copy.clock - start, dip: Self.dip(speeds, afterFirstLow: kind == .closing), fired: copy.plan.fired)
    }

    /// The deepest fall in speed that is climbed again, as a share of the fastest (closing: after
    /// the first low point, as turning back from the finger's way is no dip).
    static func dip(_ v: [Double], afterFirstLow: Bool) -> Double {
        guard !v.isEmpty else { return 0 }
        var i = 0
        if afterFirstLow { while i + 1 < v.count, v[i + 1] <= v[i] { i += 1 } }
        let top = max(1, v.max() ?? 1)
        var after = [Double](repeating: 0, count: v.count)
        for k in stride(from: v.count - 2, through: 0, by: -1) { after[k] = max(after[k + 1], v[k + 1]) }
        var worst = 0.0, before = 0.0
        for k in i..<v.count {
            before = max(before, v[k])
            worst = max(worst, min(before, after[k]) - v[k])
        }
        return worst / top
    }

    // MARK: Planning

    /// The stages of a way out from the thumbnail: for each group of layers that lies on it from
    /// the last spot, the direction in which, moved straight, it's soonest clear of them, leaning
    /// toward `want` (where it goes next) and keeping it on the screen.
    private static func stages(_ world: FlightWorld, groups: [[Int]], margin: Margin, lean: CGFloat, want: (CGPoint) -> CGPoint) -> [(layers: [Int], dir: CGVector)]? {
        var at = world.slot
        var out: [(layers: [Int], dir: CGVector)] = []
        for group in groups where world.overlapping(at, group) {
            let toward = want(at.center), aim = atan2(toward.y - at.center.y, toward.x - at.center.x)
            var best: (cost: CGFloat, dir: CGVector, spot: TurnedRect)?
            for a in stride(from: 0.0, to: 360.0, by: 3.0) {
                let angle = CGFloat(a) * .pi / 180, u = CGVector(dx: cos(angle), dy: sin(angle))
                let s = world.clearance(at, from: group, along: u)
                guard s.isFinite else { continue }
                let d = s * margin.k + margin.add, spot = at.moved(CGVector(dx: u.dx * d, dy: u.dy * d))
                let cost = d * (1 + lean * pow(1 - cos(angle - aim), 2)) + 6 * spot.outside(world.bounds)
                if best == nil || cost < best!.cost { best = (cost, u, spot) }
            }
            guard let best else { return nil }
            out.append((group, best.dir))
            at = best.spot
        }
        return out
    }

    private mutating func setPlan(_ world: FlightWorld, stages: [(layers: [Int], dir: CGVector)], margin: Margin, grow: Double, times: [Double]?) {
        let spots = stages.indices.map { Aim.spot($0) }
        var plan: Plan
        switch kind {
        case .opening:
            plan = Plan(aims: spots + [.centre], stages: stages, events: stages.map { .over($0.layers.max() ?? 0) }, margin: margin, grow: grow)
        case .closing:
            plan = Plan(aims: spots.reversed() + [.slot], stages: stages, events: stages.reversed().map { .under($0.layers.min() ?? 0) }, margin: margin, grow: 0)
        }
        plan.times = times ?? Array(repeating: .infinity, count: plan.events.count)
        plan.fired = Array(repeating: nil, count: plan.events.count)
        self.plan = plan
        spotsRead = nil
        switch kind {
        case .opening:
            goal = [Leg(aim: .fixed(center, 1, progress), t0: clock, duration: 0)]
            aim(at: plan.aims[0], over: Self.emerge)
        case .closing:
            goal = [Leg(aim: plan.aims[0], t0: clock, duration: 0)]
        }
    }

    /// Tries each way out and picks one; for each, the time to bend toward each next aim is the
    /// earliest that still gets its layers done (bisection on rehearsals), a tenth back toward safe.
    private mutating func choosePlan(_ world: FlightWorld, pageVelocity v: CGVector) {
        if kind == .opening {
            changeLayers(world, clip(world))
            changes = []
        }
        let base = self
        // Nothing lies on it: straight there.
        guard world.overlapping(world.slot, Array(world.covers.indices)) else { return setPlan(world, stages: [], margin: Self.margins[0], grow: 0, times: nil) }
        let all = Array(world.covers.indices)
        let ahead = CGPoint(x: center.x + velocity.dx / home.omega, y: center.y + velocity.dy / home.omega)
        let want: (CGPoint) -> CGPoint = kind == .opening ? { _ in CGPoint(x: world.fitted.midX, y: world.fitted.midY) } : { _ in ahead }
        // Closing: rehearsed as far as home in all but the last creep.
        let slot = world.slot.center
        let done: (PreviewFlight) -> Bool = {
            ($0.isDone && !$0.landedUncleared)
                || ($0.kind == .closing && !$0.landedUncleared && $0.level == 0 && $0.plan.next == $0.plan.events.count && $0.progress > 0.99
                    && hypot($0.center.x - slot.x, $0.center.y - slot.y) < 3)
        }
        var tried: [String] = []
        var best: (score: Double, stages: [(layers: [Int], dir: CGVector)], margin: Margin, grow: Double, times: [Double])?
        for groups in [[all], all.map { [$0] }] {
            for margin in Self.margins {
                for lean in Self.leans {
                    guard let stages = Self.stages(world, groups: groups, margin: margin, lean: lean, want: want) else { continue }
                    for grow in kind == .opening ? Self.grows : [0] {
                        let key = stages.map { "\($0.layers)\(Int($0.dir.dx * 100)),\(Int($0.dir.dy * 100))" }.joined() + "\(margin.k)\(grow)"
                        if tried.contains(key) { continue }
                        tried.append(key)
                        func run(_ times: [Double]?) -> Rehearsal {
                            var copy = base
                            copy.setPlan(world, stages: stages, margin: margin, grow: grow, times: times)
                            return copy.rehearse(world, pageVelocity: v, until: done)
                        }
                        let plain = run(nil)
                        guard plain.ok else { continue }
                        var times = [Double](repeating: .infinity, count: stages.count)
                        for j in times.indices {
                            let late = plain.fired[j] ?? 0
                            var lo = j > 0 ? min(times[j - 1], late) : 0, hi = late
                            for _ in 0..<5 {
                                let mid = (lo + hi) / 2
                                var ts = times
                                ts[j] = mid
                                if run(ts).ok { hi = mid } else { lo = mid }
                            }
                            times[j] = hi + 0.1 * (late - hi)
                        }
                        let r = run(times)
                        guard r.ok else { continue }
                        let score = r.time * (1 + 3 * r.dip)
                        if best == nil || score < best!.score { best = (score, stages, margin, grow, times) }
                    }
                }
            }
        }
        self = base
        if let best {
            setPlan(world, stages: best.stages, margin: best.margin, grow: best.grow, times: best.times)
        } else {
            // Nothing comes out clear (it should): one slide, waiting for the layers.
            let stages = Self.stages(world, groups: [all], margin: Self.margins[1], lean: Self.leans[0], want: want) ?? []
            setPlan(world, stages: stages, margin: Self.margins[1], grow: 0, times: nil)
        }
    }
}
