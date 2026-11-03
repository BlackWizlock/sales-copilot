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
        DeduplicationTests().run()
        try CalendarGridTests().run()
        CalendarNotesTests().run()
        try UpdateFeedTests().run()
        try IntelligenceTests().run()
        try SupportMaterialTests().run()
        try MeetingChatTests().run()
        PromptContextTests().run()
        try CRMChecks().run()
        try GUIInstanceTests().run()
        try MeetingLibraryTests().run()
        try ASRCatalogTests().run()
        try MCPTests().run()
        try DeletionTests().run()
        PlaybackTests().run()
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
        try SpeakerTests().run()
        print("PASS: core recording checks and integration contracts")
    }
}
