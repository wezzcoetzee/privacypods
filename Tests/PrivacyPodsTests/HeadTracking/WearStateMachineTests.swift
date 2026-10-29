import Foundation
import Testing
@testable import PrivacyPods

@Suite("Wear state machine")
struct WearStateMachineTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func running(gapTolerance: TimeInterval = 1.5) -> WearStateMachine {
        var machine = WearStateMachine(gapTolerance: gapTolerance)
        _ = machine.apply(.started(authorization: .granted, headphonesAvailable: true), at: start)
        return machine
    }

    @Test("Samples make it worn, silence past the tolerance makes it a gap, data brings it back")
    func gapWatchdog() {
        var machine = running()

        #expect(machine.apply(.sampleArrived, at: start) == .worn)
        #expect(machine.apply(.tick, at: start + 1.4) == nil)
        #expect(machine.apply(.tick, at: start + 1.6) == .unknown(.sampleGap))
        #expect(machine.apply(.tick, at: start + 5) == nil)
        #expect(machine.apply(.sampleArrived, at: start + 5.1) == .worn)
    }

    @Test("Starting without headphones is a connection problem, not a gap")
    func startedWithoutHeadphones() {
        var machine = WearStateMachine()
        let state = machine.apply(.started(authorization: .granted, headphonesAvailable: false), at: start)

        #expect(state == .unknown(.noHeadphonesConnected))
        #expect(machine.apply(.headphonesConnected, at: start + 1) == .unknown(.sampleGap))
    }

    @Test("Disconnecting outranks the gap it also causes")
    func disconnectWhileWorn() {
        var machine = running()
        _ = machine.apply(.sampleArrived, at: start)

        #expect(machine.apply(.headphonesDisconnected, at: start + 0.1) == .unknown(.noHeadphonesConnected))
        #expect(machine.apply(.tick, at: start + 10) == nil)
    }

    @Test("Refused motion access is reported as such, whatever else is true")
    func deniedAuthorization() {
        var machine = WearStateMachine()
        let state = machine.apply(.started(authorization: .denied, headphonesAvailable: true), at: start)

        #expect(state == .unknown(.permissionDenied))
    }

    @Test("A handler error parks the machine until samples resume")
    func handlerFailure() {
        var machine = running()
        _ = machine.apply(.sampleArrived, at: start)

        #expect(machine.apply(.failed(.unavailable), at: start + 0.1) == .unknown(.motionUnavailable))
        #expect(machine.apply(.sampleArrived, at: start + 0.2) == .worn)
    }

    @Test("A refused handler error is a permission problem, not an unavailable sensor")
    func refusedMidRun() {
        var machine = running()
        _ = machine.apply(.sampleArrived, at: start)

        #expect(machine.apply(.failed(.notAuthorized), at: start + 0.1) == .unknown(.permissionDenied))
        #expect(machine.apply(.tick, at: start + 10) == nil)
        #expect(machine.apply(.stopped, at: start + 11) == .unknown(.motionUnavailable))
    }

    @Test("Samples prove access, so a later run recovers from a refusal")
    func samplesClearARefusal() {
        var machine = running()

        #expect(machine.apply(.failed(.notAuthorized), at: start) == .unknown(.permissionDenied))
        #expect(machine.apply(.sampleArrived, at: start + 0.1) == .worn)
    }

    @Test("Stopping reports unavailable and repeated signals stay silent")
    func stopIsIdempotent() {
        var machine = running()
        _ = machine.apply(.sampleArrived, at: start)

        #expect(machine.apply(.stopped, at: start + 0.1) == .unknown(.motionUnavailable))
        #expect(machine.apply(.stopped, at: start + 0.2) == nil)
        #expect(machine.apply(.tick, at: start + 10) == nil)
    }
}
