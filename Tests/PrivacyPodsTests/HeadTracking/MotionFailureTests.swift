import CoreMotion
import Foundation
import Testing
@testable import PrivacyPods

/// The one piece of CoreMotion bridging with a decision in it: which handler errors mean the
/// user refused access, as opposed to the sensor being the sensor. Getting it wrong sends the
/// user to a "motion unavailable" dead end instead of System Settings.
@Suite("Motion handler failures")
struct MotionFailureTests {
    private func failure(_ code: CMError) -> WearStateMachine.Failure {
        WearStateMachine.Failure(NSError(domain: CMErrorDomain, code: Int(code.rawValue)))
    }

    @Test("Both of CoreMotion's refusal codes are a refusal")
    func refusals() {
        #expect(failure(CMErrorNotAuthorized) == .notAuthorized)
        #expect(failure(CMErrorMotionActivityNotAuthorized) == .notAuthorized)
    }

    @Test("Every other CoreMotion error is the sensor being unavailable")
    func otherCoreMotionErrors() {
        #expect(failure(CMErrorNotAvailable) == .unavailable)
        #expect(failure(CMErrorNotEntitled) == .unavailable)
        #expect(failure(CMErrorUnknown) == .unavailable)
    }

    @Test("A matching code from another domain is not a refusal")
    func foreignDomain() {
        let error = NSError(domain: NSPOSIXErrorDomain,
                            code: Int(CMErrorNotAuthorized.rawValue))
        #expect(WearStateMachine.Failure(error) == .unavailable)
    }
}
