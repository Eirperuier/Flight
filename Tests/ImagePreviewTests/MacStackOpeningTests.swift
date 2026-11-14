import CoreGraphics
import Testing
@testable import ImagePreview

/// The picture under the stack in a Mac conversation (as logged from the Gallery): over the
/// pictures below it, the composer, the header, the sidebar column and an empty layer.
private let macStack: FlightWorld = {
    func q(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ t: CGFloat) -> TurnedRect { TurnedRect(center: CGPoint(x: x, y: y), size: CGSize(width: w, height: h), turn: t) }
    return FlightWorld(
        slot: q(438, 169.3, 174, 232, 0.009),
        covers: [[q(492, 373.3, 180, 240, -0.009), q(492, 373.3, 180, 240, -0.009)],
                 [q(819.5, 585.8, 225, 169, -0.017), q(819.5, 585.8, 225, 169, -0.017), q(914, 765.3, 180, 240, 0.017), q(914, 765.3, 180, 240, 0.017)],
                 [q(380, 720.5, 40, 40, 0), q(702, 722.8, 580, 35.5, 0)],
                 [q(676.5, 56.5, 55, 25, 0), q(676.5, 28, 40, 40, 0), q(676.5, 28, 40, 40, 0)],
                 [q(168, 384, 320, 752, 0)],
                 []],
        paged: [true, true, false, false, false, false],
        fitted: CGRect(x: 224, y: 0, width: 576, height: 768),
        bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))
}()

/// However far ahead its plan is made, it opens over every layer.
@Test(arguments: [1.0 / 30, 0.05, 0.07, 0.1])
func opensOverTheMacStackPlannedAhead(_ ahead: Double) {
    var flight = PreviewFlight.opening(macStack, planned: false).plannedAhead(by: ahead, world: macStack)
    while !flight.isDone, flight.clock < 3 { flight.advance(1.0 / 120, world: macStack) }
    #expect(flight.isDone && !flight.landedUncleared, "\(flight.summary)")
}

/// Its plan made for 0.033 s and come at 0.06 s (as logged): taken from there, it opens over all.
@Test(arguments: [0.04, 0.06, 0.1])
func opensOverTheMacStackWithAPlanComeLate(_ at: Double) {
    let start = PreviewFlight.opening(macStack, planned: false)
    let planned = start.plannedAhead(by: 1.0 / 30, world: macStack)
    var flight = start
    while flight.clock < at { flight.advance(1.0 / 120, world: macStack) }
    flight.adoptPlan(of: planned, world: macStack)
    while !flight.isDone, flight.clock < 3 { flight.advance(1.0 / 120, world: macStack) }
    #expect(flight.isDone && !flight.landedUncleared, "\(flight.summary)")
}

/// The picture let go of as it opens (a click's press ends): its place grows back to full size
/// a moment in. The plan was made for the pressed size; it still opens over every layer.
@Test(arguments: [0.05, 0.1, 0.15, 0.2, 0.25, 0.35])
func opensOverTheMacStackAsThePressEnds(_ at: Double) {
    var released = macStack
    released.slot.size = CGSize(width: 180, height: 240)
    for ahead in [1.0 / 30, 0.07] {
        var flight = PreviewFlight.opening(macStack, planned: false).plannedAhead(by: ahead, world: macStack)
        while !flight.isDone, flight.clock < 3 { flight.advance(1.0 / 120, world: flight.clock < at ? macStack : released) }
        #expect(flight.isDone && !flight.landedUncleared, "ahead \(ahead): \(flight.summary)")
    }
}
