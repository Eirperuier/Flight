import CoreGraphics
import Testing
@testable import Flight

@Test func springVectorSettlesOnItsTarget() {
    var spring = SpringVector(values: [0, 10], tolerances: [0.01, 0.01], spring: .transition)
    spring.retarget([100, -20])
    var time = 0.0
    while !spring.step(1.0 / 120) { time += 1.0 / 120; #expect(time < 3) }
    #expect(spring.values == [100, -20])
}

@Test func retargetingKeepsVelocity() {
    var spring = SpringVector(values: [0], tolerances: [0.01], spring: .transition)
    spring.retarget([100])
    for _ in 0..<10 { _ = spring.step(1.0 / 120) }
    let moving = spring.velocities[0]
    #expect(moving > 0)
    spring.retarget([0])
    #expect(spring.velocities[0] == moving)
    _ = spring.step(1.0 / 120)
    // Still going out for a moment: turned, not stopped.
    #expect(spring.velocities[0] > 0)
}

#if canImport(UIKit)
import UIKit

@Test func placeRoundTripsThroughItsVector() {
    let place = FlightPlace(frame: CGRect(x: 10, y: 20, width: 30, height: 40), turn: 0.1, corner: 6, extras: [0.5])
    #expect(FlightPlace(place.vector) == place)
    #expect(place.frame == CGRect(x: 10, y: 20, width: 30, height: 40))
}

@MainActor @Test func aPieceFollowsAMovingTargetAndLandsOnIt() {
    var target = FlightPlace(frame: CGRect(x: 200, y: 400, width: 80, height: 80))
    var shown: FlightPlace?
    let piece = FlightPiece(from: FlightPlace(frame: CGRect(x: 0, y: 0, width: 300, height: 300)), target: { target }) { shown = $0 }
    let group = FlightGroup(pieces: [piece])
    var landed = false
    group.onLanded = { landed = true }
    group.start()
    // Drive it by hand: the content scrolls 5 points a frame while it flies.
    for _ in 0..<240 where !landed {
        target.center.y -= 5
        group.step(1.0 / 120)
    }
    #expect(landed)
    #expect(shown?.frame == target.frame)
    group.stop()
}

@MainActor @Test func aPieceSetsOffAtTheFingersSpeed() {
    let piece = FlightPiece(from: FlightPlace(frame: CGRect(x: 0, y: 0, width: 10, height: 10)), velocity: CGPoint(x: 900, y: 0), target: { nil }) { _ in }
    // No target yet: it coasts on its speed.
    let group = FlightGroup(pieces: [piece])
    group.step(1.0 / 120)
    #expect(piece.place.center.x > 5)
}

@Test func placesMix() {
    let a = FlightPlace(frame: CGRect(x: 0, y: 0, width: 10, height: 10), corner: 2, extras: [0])
    let b = FlightPlace(frame: CGRect(x: 100, y: 0, width: 30, height: 10), corner: 6, extras: [1])
    let m = a.mixed(with: b, 0.5)
    #expect(m.size.width == 20 && m.corner == 4 && m.extras == [0.5])
}

@MainActor @Test func aPieceIgnoresTouches() {
    let view = UIView()
    _ = FlightPiece(view: view, from: FlightPlace(frame: .zero), target: { nil })
    #expect(!view.isUserInteractionEnabled)
}
#endif
