import CoreGraphics
import Testing
@testable import ImagePreview

// The prototype's page: a phone, a bar over the top, a composer at the bottom, three pictures
// lying on each other (the later over the earlier).
private let bounds = CGRect(x: 0, y: 0, width: 440, height: 956)
private let header = TurnedRect(CGRect(x: 0, y: 0, width: 440, height: 112))
private let composer = TurnedRect(CGRect(x: 0, y: 956 - 60, width: 440, height: 60))
private let deg = CGFloat.pi / 180
private func picture(_ i: Int, scroll: CGFloat) -> TurnedRect {
    [TurnedRect(center: CGPoint(x: 337, y: 150 + scroll), size: CGSize(width: 174, height: 233), turn: deg),
     TurnedRect(center: CGPoint(x: 286, y: 330 + scroll), size: CGSize(width: 218, height: 164), turn: -deg),
     TurnedRect(center: CGPoint(x: 330, y: 495 + scroll), size: CGSize(width: 174, height: 233), turn: deg)][i]
}
private func world(_ i: Int, scroll: CGFloat) -> FlightWorld {
    let later = (i + 1..<3).map { [picture($0, scroll: scroll)] }
    let slot = picture(i, scroll: scroll)
    let k = min(bounds.width / slot.size.width, bounds.height / slot.size.height)
    let fitted = CGRect(x: 220 - slot.size.width * k / 2, y: 478 - slot.size.height * k / 2, width: slot.size.width * k, height: slot.size.height * k)
    return FlightWorld(slot: slot, covers: later + [[header], [composer]], paged: later.map { _ in true } + [false, false], fitted: fitted, bounds: bounds)
}

/// Runs a flight to the end (the page moving at `page` pt/s), checking that every change of
/// layer happens with none of the layers it passes lying on the image.
private func fly(_ flight: inout PreviewFlight, _ i: Int, scroll: CGFloat, page: CGFloat = 0) -> (time: Double, changes: Int) {
    var s = scroll, changes = 0
    while !flight.isDone, flight.clock < 3 {
        s += page / 240
        let w = world(i, scroll: s), before = flight.level
        flight.advance(1.0 / 240, world: w)
        let after = flight.level
        if after != before {
            changes += 1
            for layer in min(before, after)..<max(before, after) {
                #expect(w.clear(flight.clip(w), of: layer), "layer \(layer) lies on the image as it changes \(before) → \(after)")
            }
        }
    }
    return (flight.clock, changes)
}

@Test func clearanceIsTheWayOut() {
    let a = TurnedRect(CGRect(x: 0, y: 0, width: 100, height: 100))
    let b = TurnedRect(CGRect(x: 0, y: 80, width: 100, height: 100))
    #expect(abs(a.clearance(from: b, along: CGVector(dx: 0, dy: -1)) - 20) < 0.001)
    #expect(abs(a.clearance(from: b, along: CGVector(dx: 1, dy: 0)) - 100) < 0.001)
    #expect(a.clearance(from: b.moved(CGVector(dx: 0, dy: 30)), along: CGVector(dx: 1, dy: 0)) == 0)
}

@Test(arguments: [(0, -40.0), (1, 60.0), (2, 380.0), (2, 60.0)])
func opensClearOfEveryLayer(_ i: Int, _ scroll: Double) {
    var flight = PreviewFlight.opening(world(i, scroll: scroll))
    let r = fly(&flight, i, scroll: scroll)
    #expect(flight.isDone && flight.isOverAll)
    #expect(r.time < 1.2)
}

@Test(arguments: [(0, -40.0), (1, 60.0), (2, 380.0)])
func closesUnderEveryLayer(_ i: Int, _ scroll: Double) {
    let w = world(i, scroll: scroll)
    var flight = PreviewFlight.closing(w, center: CGPoint(x: 250, y: 620), size: CGSize(width: 300, height: 400),
                                       velocity: CGVector(dx: 240, dy: 1200), backdrop: 0.4)
    let r = fly(&flight, i, scroll: scroll)
    #expect(flight.isDone && flight.level == 0)
    #expect(r.changes > 0)
    #expect(r.time < 1.5)
}

@Test(arguments: [(0, -40.0, 260.0), (1, 60.0, -260.0)])
func theLayersStayRightWhileThePageMoves(_ i: Int, _ scroll: Double, _ page: Double) {
    var opening = PreviewFlight.opening(world(i, scroll: scroll))
    _ = fly(&opening, i, scroll: scroll, page: page)
    #expect(opening.isDone && opening.isOverAll)
    var closing = PreviewFlight.closing(world(i, scroll: scroll), center: CGPoint(x: 250, y: 620), size: CGSize(width: 300, height: 400),
                                        velocity: CGVector(dx: 240, dy: 1200), backdrop: 0.4)
    _ = fly(&closing, i, scroll: scroll, page: page)
    #expect(closing.isDone && closing.level == 0)
}

/// Planned ahead elsewhere while it flies on unplanned, then put in its place where it was
/// planned for: the same as planned at once, shifted by the wait.
@Test(arguments: [(0, -40.0), (1, 60.0), (2, 380.0)])
func aPlanMadeAheadTakesOverWhereItWasMadeFor(_ i: Int, _ scroll: Double) {
    let w = world(i, scroll: scroll)
    let v = PreviewFlight.released(CGVector(dx: 240, dy: 1200), from: CGPoint(x: 250, y: 620), toward: w.slot.center)
    let flights = [PreviewFlight.opening(w, planned: false),
                   PreviewFlight.closing(w, center: CGPoint(x: 250, y: 620), size: CGSize(width: 300, height: 400), velocity: v, backdrop: 0.4, planned: false)]
    for start in flights {
        var flight = start
        var planned = flight.plannedAhead(by: 0.1, world: w)
        while flight.clock + 1.0 / 60 < planned.clock { flight.advance(1.0 / 60, world: w) }
        flight.advance(planned.clock - flight.clock, world: w)
        // Up to there the same flight: nothing shows as the planned one takes over.
        #expect(hypot(flight.center.x - planned.center.x, flight.center.y - planned.center.y) < 1)
        _ = fly(&planned, i, scroll: scroll)
        #expect(planned.isDone && !planned.landedUncleared)
        #expect(start.kind == .opening ? planned.isOverAll : planned.level == 0)
        #expect(planned.clock < 1.6)
    }
}

@Test(arguments: [(0, -40.0), (1, 60.0), (2, 380.0)])
func aTapOnTheWayHomeOpensItAgain(_ i: Int, _ scroll: Double) {
    let w = world(i, scroll: scroll)
    var closing = PreviewFlight.closing(w, center: CGPoint(x: 250, y: 620), size: CGSize(width: 300, height: 400), velocity: .zero, backdrop: 0.4)
    for _ in 0..<60 { closing.advance(1.0 / 240, world: w) }
    let clip = closing.clip(w)
    var opening = PreviewFlight.opening(w, from: (clip.center, clip.size, closing.velocity, closing.level))
    _ = fly(&opening, i, scroll: scroll)
    #expect(opening.isDone && opening.isOverAll)
}

/// Its plan comes late (a slow build, a busy machine): the image waits for it under the layers,
/// not growing into them on the way to the middle, and then opens over all of them.
@Test(arguments: [(0, -40.0), (1, 60.0), (2, 380.0)])
func opensOverEveryLayerWithALatePlan(_ i: Int, _ scroll: Double) {
    let w = world(i, scroll: scroll)
    let start = PreviewFlight.opening(w, planned: false)
    let planned = start.plannedAhead(by: 0.05, world: w)
    var flight = start
    for _ in 0..<240 { flight.advance(1.0 / 240, world: w) }
    #expect(flight.progress < 0.05 && !flight.isOverAll)
    flight.adoptPlan(of: planned, world: w)
    var left = flight
    _ = fly(&left, i, scroll: scroll)
    #expect(left.isDone && left.isOverAll && !left.landedUncleared)
}
