import XCTest
@testable import BlobCanvas

final class CheckpointRingTests: XCTestCase {

    func testPushAndTakeNewest() {
        var ring = CheckpointRing<String>(capacity: 4)
        ring.push(key: 0, "a")
        ring.push(key: 1, "b")
        ring.push(key: 2, "c")
        XCTAssertEqual(ring.take(key: 2), "c")
        XCTAssertEqual(ring.take(key: 1), "b")
        XCTAssertEqual(ring.take(key: 0), "a")
        XCTAssertTrue(ring.isEmpty)
    }

    func testTakeOnlyNewestKey() {
        var ring = CheckpointRing<String>(capacity: 4)
        ring.push(key: 0, "a")
        ring.push(key: 1, "b")
        // Asking for a non-newest key returns nil (non-contiguous → re-bake).
        XCTAssertNil(ring.take(key: 0))
        XCTAssertEqual(ring.take(key: 1), "b")
    }

    func testEvictsOldestBeyondCapacity() {
        var ring = CheckpointRing<Int>(capacity: 2)
        ring.push(key: 0, 0)
        ring.push(key: 1, 1)
        ring.push(key: 2, 2)   // evicts key 0
        XCTAssertEqual(ring.count, 2)
        XCTAssertNil(ring.take(key: 0))
        XCTAssertEqual(ring.take(key: 2), 2)
    }

    func testPushSupersedesHigherKeys() {
        var ring = CheckpointRing<String>(capacity: 4)
        ring.push(key: 0, "a")
        ring.push(key: 1, "b")
        ring.push(key: 2, "c")
        // Re-committing at key 1 (after undo) drops the stale key-2 checkpoint.
        ring.push(key: 1, "b2")
        XCTAssertNil(ring.take(key: 2))
        XCTAssertEqual(ring.take(key: 1), "b2")
    }

    func testZeroCapacityIsNoop() {
        var ring = CheckpointRing<Int>(capacity: 0)
        ring.push(key: 0, 1)
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.take(key: 0))
    }

    func testInvalidateClears() {
        var ring = CheckpointRing<Int>(capacity: 4)
        ring.push(key: 0, 1)
        ring.push(key: 1, 2)
        ring.invalidate()
        XCTAssertTrue(ring.isEmpty)
        XCTAssertNil(ring.take(key: 1))
    }
}
