import XCTest
@testable import HavmCore

final class ConfigTests: XCTestCase {
    func testMemorySizeParsing() throws {
        XCTAssertEqual(try MemorySize.parse("4 GiB"), 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("2048 MiB"), 2048 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("1 GiB"), 1024 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("256 MiB"), 256 * 1024 * 1024)
        XCTAssertEqual(try MemorySize.parse("1024"), 1024)
    }

    func testMemorySizeDescription() {
        XCTAssertEqual(MemorySize(bytes: 4 * 1024 * 1024 * 1024).description, "4 GiB")
        XCTAssertEqual(MemorySize(bytes: 2048 * 1024 * 1024).description, "2 GiB")
    }

    func testEffectiveDefaults() {
        let config = HavmConfig.defaults
        XCTAssertGreaterThan(config.effectiveCPUCount, 0)
        XCTAssertEqual(config.effectiveMemorySize, 4 * 1024 * 1024 * 1024)
        XCTAssertEqual(config.effectiveDiskSize, 32 * 1024 * 1024 * 1024)
        XCTAssertEqual(config.effectiveNetworkType, .nat)
        XCTAssertEqual(config.effectiveReleaseChannel, .stable)
        XCTAssertEqual(config.effectiveShutdownTimeout, 30)
    }

    func testKnownCoordinatorsNotEmpty() {
        XCTAssertFalse(KnownCoordinator.all.isEmpty)
    }

    func testKnownCoordinatorsHaveValidIDs() {
        for coordinator in KnownCoordinator.all {
            XCTAssertGreaterThan(coordinator.vendorId, 0, "\(coordinator.name) should have non-zero vendorId")
            XCTAssertGreaterThan(coordinator.productId, 0, "\(coordinator.name) should have non-zero productId")
        }
    }
}
