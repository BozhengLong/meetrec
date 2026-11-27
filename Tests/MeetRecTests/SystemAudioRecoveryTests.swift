import ScreenCaptureKit
import XCTest
@testable import MeetRec

final class SystemAudioRecoveryTests: XCTestCase {
    func testShortInterruptionRetriesWithoutWarning() {
        var recovery = SystemAudioRecovery(now: 0)
        XCTAssertEqual(recovery.poll(at: 0), .connect)
        recovery.receivedBuffer(at: 0.1)
        recovery.interrupted(at: 60)
        XCTAssertEqual(recovery.poll(at: 60.1), .none)
        XCTAssertEqual(recovery.poll(at: 60.25), .connect)
        XCTAssertFalse(recovery.shouldWarn(at: 60.25))
        recovery.receivedBuffer(at: 61)
        XCTAssertFalse(recovery.shouldWarn(at: 65.5))
        recovery.interrupted(at: 70)
        XCTAssertEqual(recovery.poll(at: 70.25), .connect)
    }

    func testPersistentFailureWarnsAndKeepsTryingUntilFirstBuffer() {
        var recovery = SystemAudioRecovery(now: 0)
        XCTAssertEqual(recovery.poll(at: 0), .connect)
        recovery.receivedBuffer(at: 0.1)
        recovery.interrupted(at: 10)
        XCTAssertEqual(recovery.poll(at: 10.25), .connect)
        recovery.interrupted(at: 10.3)
        XCTAssertEqual(recovery.poll(at: 10.7), .none)
        XCTAssertEqual(recovery.poll(at: 10.8), .connect)
        XCTAssertFalse(recovery.shouldWarn(at: 14.99))
        XCTAssertTrue(recovery.shouldWarn(at: 15))
        XCTAssertEqual(recovery.poll(at: 18.81), .disconnect)
        XCTAssertEqual(recovery.poll(at: 19.82), .connect)
        XCTAssertTrue(recovery.shouldWarn(at: 20))
        recovery.receivedBuffer(at: 20.1)
        XCTAssertFalse(recovery.shouldWarn(at: 20.1))
    }

    func testMissingBuffersWithoutDelegateErrorTriggerRecovery() {
        var recovery = SystemAudioRecovery(now: 0)
        XCTAssertEqual(recovery.poll(at: 0), .connect)
        for second in 1...20 {
            recovery.receivedBuffer(at: Double(second))
            XCTAssertEqual(recovery.poll(at: Double(second)), .none)
            XCTAssertFalse(recovery.shouldWarn(at: Double(second)))
        }
        XCTAssertEqual(recovery.poll(at: 24.99), .none)
        XCTAssertEqual(recovery.poll(at: 25), .disconnect)
        XCTAssertTrue(recovery.shouldWarn(at: 25))
        XCTAssertEqual(recovery.poll(at: 25.25), .connect)
    }

    func testExplicitStopAndPermissionErrorsDoNotRestartCapture() {
        XCTAssertTrue(AudioCaptureError.mayRetry(SCStreamError(.failedApplicationConnectionInterrupted)))
        XCTAssertFalse(AudioCaptureError.mayRetry(SCStreamError(.userStopped)))
        XCTAssertFalse(AudioCaptureError.mayRetry(SCStreamError(.userDeclined)))
        XCTAssertFalse(AudioCaptureError.mayRetry(AudioCaptureError.noPermission))

        var recovery = SystemAudioRecovery(now: 0)
        XCTAssertEqual(recovery.poll(at: 0), .connect)
        recovery.interrupted(at: 1, retry: false)
        XCTAssertTrue(recovery.shouldWarn(at: 1))
        XCTAssertEqual(recovery.poll(at: 60), .none)
    }
}
