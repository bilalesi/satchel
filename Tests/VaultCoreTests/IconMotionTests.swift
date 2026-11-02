import XCTest
@testable import VaultCore

final class IconMotionTests: XCTestCase {
    /// A motion that does not end where it began would snap when the view goes back to rest.
    func testEveryMotionStartsAndEndsAtRest() {
        for motion in IconMotion.allCases {
            for p in [0.0, 1.0] {
                let pose = motion.pose(at: p)
                XCTAssertEqual(pose.sx, 1, accuracy: 1e-9, "\(motion) sx at \(p)")
                XCTAssertEqual(pose.sy, 1, accuracy: 1e-9, "\(motion) sy at \(p)")
                XCTAssertEqual(pose.dx, 0, accuracy: 1e-9, "\(motion) dx at \(p)")
                XCTAssertEqual(pose.dy, 0, accuracy: 1e-9, "\(motion) dy at \(p)")
                XCTAssertEqual(pose.opacity, 1, accuracy: 1e-9, "\(motion) opacity at \(p)")
                let turns = pose.rotation / 360
                XCTAssertEqual(turns, turns.rounded(), accuracy: 1e-9, "\(motion) rotation at \(p)")
            }
        }
    }

    func testEveryMotionStaysLegibleAndSomethingMoves() {
        for motion in IconMotion.allCases {
            var moved = false
            for step in 0...100 {
                let pose = motion.pose(at: Double(step) / 100)
                XCTAssertTrue((0.2...1.5).contains(pose.sx) && (0.2...1.5).contains(pose.sy), "\(motion) scale")
                XCTAssertTrue(abs(pose.dx) <= 6 && abs(pose.dy) <= 6, "\(motion) shift")
                XCTAssertTrue((0.2...1).contains(pose.opacity), "\(motion) opacity")
                if pose != .rest { moved = true }
            }
            XCTAssertTrue(moved, "\(motion) never moves")
        }
    }

    func testProgressOutsideTheRangeIsClamped() {
        XCTAssertEqual(IconMotion.hop.pose(at: -3), IconMotion.hop.pose(at: 0))
        XCTAssertEqual(IconMotion.hop.pose(at: 9), IconMotion.hop.pose(at: 1))
    }

    func testIconsGetTheirMotionAndUnknownOnesPop() {
        XCTAssertEqual(IconMotion.forIcon("starFull"), .spinStar)
        XCTAssertEqual(IconMotion.forIcon("history"), .rewind)
        XCTAssertEqual(IconMotion.forIcon("key"), .turnKey)
        XCTAssertEqual(IconMotion.forIcon("somethingNew"), .pop)
    }
}
