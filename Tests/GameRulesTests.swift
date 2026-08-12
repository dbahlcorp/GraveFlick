import CoreGraphics
import XCTest
@testable import GraveFlick

final class GameRulesTests: XCTestCase {
    func testFlickVelocityUsesRecentTouchHistory() {
        let samples: [(point: CGPoint, time: TimeInterval)] = [
            (CGPoint(x: 0, y: 0), 0),
            (CGPoint(x: 20, y: 10), 0.20),
            (CGPoint(x: 120, y: 60), 0.30)
        ]

        let velocity = FlickMath.velocity(from: samples)

        XCTAssertEqual(velocity.dx, 1_000, accuracy: 0.01)
        XCTAssertEqual(velocity.dy, 500, accuracy: 0.01)
    }

    func testFlickVelocityIsClamped() {
        let velocity = FlickMath.clamped(CGVector(dx: 10_000, dy: 0), maximum: 2_200)
        XCTAssertEqual(velocity.dx, 2_200, accuracy: 0.01)
        XCTAssertEqual(velocity.dy, 0, accuracy: 0.01)
    }

    func testComboAndBruteScoring() {
        XCTAssertEqual(GameRules.score(for: .walker, combo: 1), 100)
        XCTAssertEqual(GameRules.score(for: .walker, combo: 3), 150)
        XCTAssertEqual(GameRules.score(for: .brute, combo: 2), 275)
    }
}
