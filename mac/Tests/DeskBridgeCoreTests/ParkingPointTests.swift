import CoreGraphics
@testable import DeskBridgeCore
import Testing

struct ParkingPointTests {
    private let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let none: (CGPoint) -> Bool = { _ in false }

    @Test func parksInsideTheScreenAwayFromTheEdge() {
        #expect(ParkingPoint.find(from: CGPoint(x: 900, y: 1079), edge: .bottom, display: display, isOccupied: none)
            == CGPoint(x: 900, y: 959))
        #expect(ParkingPoint.find(from: CGPoint(x: 900, y: 0), edge: .top, display: display, isOccupied: none)
            == CGPoint(x: 900, y: 120))
        #expect(ParkingPoint.find(from: CGPoint(x: 1919, y: 500), edge: .right, display: display, isOccupied: none)
            == CGPoint(x: 1799, y: 500))
        #expect(ParkingPoint.find(from: CGPoint(x: 0, y: 500), edge: .left, display: display, isOccupied: none)
            == CGPoint(x: 120, y: 500))
    }

    @Test func skipsOccupiedPointsAndTriesFurtherInsideThenSideways() {
        // Everything within 200 px of the bottom is covered (a Dock).
        let dock: (CGPoint) -> Bool = { $0.y > 880 }
        let point = ParkingPoint.find(from: CGPoint(x: 900, y: 1079), edge: .bottom, display: display, isOccupied: dock)
        #expect(point == CGPoint(x: 900, y: 839)) // 240 px inward, same x

        let leftHalfCovered: (CGPoint) -> Bool = { $0.x < 900 }
        let sideways = ParkingPoint.find(
            from: CGPoint(x: 900, y: 1079), edge: .bottom, display: display, isOccupied: leftHalfCovered
        )
        #expect(sideways == CGPoint(x: 900, y: 959)) // offset 0 is free
    }

    @Test func staysInsideTheDisplayMargin() {
        // Near the left screen border a negative offset would leave the display; those candidates are skipped.
        let point = ParkingPoint.find(from: CGPoint(x: 30, y: 1079), edge: .bottom, display: display) { $0.x < 100 }
        #expect(point.x >= 100 + 0 && display.insetBy(dx: ParkingPoint.margin, dy: ParkingPoint.margin).contains(point))
    }

    @Test func fallsBackToTheFirstInwardPointWhenEverythingIsOccupied() {
        let point = ParkingPoint.find(from: CGPoint(x: 900, y: 1079), edge: .bottom, display: display) { _ in true }
        #expect(point == CGPoint(x: 900, y: 959))
    }
}
