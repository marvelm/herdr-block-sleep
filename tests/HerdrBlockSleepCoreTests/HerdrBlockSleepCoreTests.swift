import Foundation
import XCTest
@testable import HerdrBlockSleepCore

final class HerdrBlockSleepCoreTests: XCTestCase {
    func testConfigUsesDefaults() {
        let config = Config(environment: [:])

        XCTAssertEqual(config.herdrBin, "herdr")
        XCTAssertEqual(config.socketPath, NSHomeDirectory() + "/.config/herdr/herdr.sock")
        XCTAssertEqual(config.stateDir.path, NSHomeDirectory() + "/.local/state/herdr-block-sleep")
        XCTAssertEqual(config.lidCheckSeconds, 15)
        XCTAssertEqual(config.reconcileSeconds, 300)
        XCTAssertEqual(config.maxFailures, 4)
        XCTAssertEqual(config.logURL.lastPathComponent, "block-sleep.log")
        XCTAssertEqual(config.pidURL.lastPathComponent, "daemon.pid")
        XCTAssertEqual(config.statusURL.lastPathComponent, "status.json")
    }

    func testConfigUsesEnvironmentOverrides() {
        let config = Config(environment: [
            "HERDR_BIN_PATH": "/tmp/herdr",
            "HERDR_SOCKET_PATH": "/tmp/herdr.sock",
            "HERDR_PLUGIN_STATE_DIR": "/tmp/state",
            "HERDR_BLOCK_SLEEP_LID_CHECK_SECONDS": "7",
            "HERDR_BLOCK_SLEEP_RECONCILE_SECONDS": "11",
            "HERDR_BLOCK_SLEEP_MAX_FAILURES": "13",
        ])

        XCTAssertEqual(config.herdrBin, "/tmp/herdr")
        XCTAssertEqual(config.socketPath, "/tmp/herdr.sock")
        XCTAssertEqual(config.stateDir.path, "/tmp/state")
        XCTAssertEqual(config.lidCheckSeconds, 7)
        XCTAssertEqual(config.reconcileSeconds, 11)
        XCTAssertEqual(config.maxFailures, 13)
    }

    func testConfigSupportsLegacyMaxFailuresName() {
        let config = Config(environment: ["HERDR_PREVENT_SLEEP_MAX_FAILURES": "9"])

        XCTAssertEqual(config.maxFailures, 9)
    }

    func testConfigInvalidNumbersFallBackToDefaults() {
        let config = Config(environment: [
            "HERDR_BLOCK_SLEEP_LID_CHECK_SECONDS": "not-a-number",
            "HERDR_BLOCK_SLEEP_RECONCILE_SECONDS": "not-a-number",
            "HERDR_BLOCK_SLEEP_MAX_FAILURES": "not-a-number",
        ])

        XCTAssertEqual(config.lidCheckSeconds, 15)
        XCTAssertEqual(config.reconcileSeconds, 300)
        XCTAssertEqual(config.maxFailures, 4)
    }

    func testAssertionDecisionTreatsClosedLidAsInactive() {
        XCTAssertEqual(
            assertionDecision(lid: "Yes", workingCount: 3),
            AssertionDecision(desired: false, reason: "lid-closed")
        )
    }

    func testAssertionDecisionTreatsWorkingAgentsAsActiveWhenLidOpen() {
        XCTAssertEqual(
            assertionDecision(lid: "No", workingCount: 2),
            AssertionDecision(desired: true, reason: "working-agents=2")
        )
    }

    func testAssertionDecisionTreatsIdleAsInactive() {
        XCTAssertEqual(
            assertionDecision(lid: "No", workingCount: 0),
            AssertionDecision(desired: false, reason: "idle")
        )
    }

    func testAssertionDecisionAllowsAssertionWhenLidUnknownAndAgentsWork() {
        XCTAssertEqual(
            assertionDecision(lid: nil, workingCount: 1),
            AssertionDecision(desired: true, reason: "working-agents=1")
        )
    }

    func testParseAgentSnapshotCountsWorkingAndSortsUniquePanes() {
        let snapshot = parseAgentSnapshot([
            ["agent_status": "working", "pane_id": "pane-b"],
            ["agent_status": "idle", "pane_id": "pane-a"],
            ["agent_status": "working", "pane_id": "pane-a"],
            ["agent_status": "unknown"],
        ])

        XCTAssertEqual(snapshot.workingCount, 2)
        XCTAssertEqual(snapshot.paneIDs, ["pane-a", "pane-b"])
    }

    func testReadPIDParsesWhitespacePaddedInteger() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("daemon.pid")
        try " 1234\n".write(to: pidFile, atomically: true, encoding: .utf8)

        XCTAssertEqual(readPID(from: pidFile), 1234)
    }

    func testReadPIDRejectsMissingAndInvalidFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("daemon.pid")

        XCTAssertNil(readPID(from: pidFile))
        try "not-a-pid".write(to: pidFile, atomically: true, encoding: .utf8)
        XCTAssertNil(readPID(from: pidFile))
    }
}
