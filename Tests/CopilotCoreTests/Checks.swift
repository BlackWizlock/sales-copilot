import Foundation

func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, file: StaticString = #file, line: UInt = #line) {
    precondition(lhs == rhs, "Expected \(rhs), got \(lhs) at \(file):\(line)")
}
func expectEqual(_ lhs: Double, _ rhs: Double, accuracy: Double, file: StaticString = #file, line: UInt = #line) {
    precondition(abs(lhs-rhs) <= accuracy, "Expected \(rhs), got \(lhs) at \(file):\(line)")
}
func expectEqual(_ lhs: Float, _ rhs: Float, accuracy: Float, file: StaticString = #file, line: UInt = #line) {
    precondition(abs(lhs-rhs) <= accuracy, "Expected \(rhs), got \(lhs) at \(file):\(line)")
}
func expectThrows<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
    do { _ = try expression() } catch { return }
    preconditionFailure("Expected error at \(file):\(line)")
}
@main struct CoreChecks {
    static func main() throws {
        try SessionTests().testPCMFileHasCorrectLengthClippingAndRoundTrip()
        try SessionTests().testManifestRoundTripAndInterruptedRecovery()
        try SessionTests().testCannotEscapeSessionDirectory()
        try SessionTests().testOrphanAudioChunkRecoveredAfterInterruptedWrite()
        try SessionTests().testChunkWriteFailureReturnsAndTailCanBeRecovered()
        try SessionTests().testPartialTailAndGapKeepTheirOriginalTimes()
        SessionTests().testTruncatedWaveIsRejected()
        try SessionTests().testBrokenMeetingDoesNotHideHistoryAndAudioCanBeRecovered()
        try WhisperTests().testOffsetsAreRelativeToMeetingAndSilenceIsFiltered()
        WhisperTests().testMalformedOutputFailsInsteadOfEmptySuccess()
        print("PASS: 10 core checks")
    }
}
