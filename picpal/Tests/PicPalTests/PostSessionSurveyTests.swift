import Testing
@testable import PicPal

@Suite("PostSessionSurvey", .serialized)
struct PostSessionSurveyTests {

    @Test("lastResponse is nil when no response has been recorded")
    func lastResponse_nilWhenAbsent() {
        PostSessionSurvey.reset()
        #expect(PostSessionSurvey.lastResponse() == nil)
    }

    @Test("record stores a valid response")
    func record_storesResponse() {
        PostSessionSurvey.reset()
        PostSessionSurvey.record(response: 4)
        #expect(PostSessionSurvey.lastResponse() == 4)
    }

    @Test("record ignores a response below the valid range")
    func record_outOfRange_ignored() {
        PostSessionSurvey.reset()
        PostSessionSurvey.record(response: 0)
        #expect(PostSessionSurvey.lastResponse() == nil)
    }

    @Test("record ignores a response above the valid range")
    func record_outOfRange_high_ignored() {
        PostSessionSurvey.reset()
        PostSessionSurvey.record(response: 6)
        #expect(PostSessionSurvey.lastResponse() == nil)
    }

    @Test("record overwrites the previous response")
    func record_overwrites() {
        PostSessionSurvey.reset()
        PostSessionSurvey.record(response: 4)
        PostSessionSurvey.record(response: 2)
        #expect(PostSessionSurvey.lastResponse() == 2)
    }

    @Test("sessionCueThreshold is 3")
    func sessionCueThreshold_isThree() {
        #expect(PostSessionSurvey.sessionCueThreshold == 3)
    }

    @Test("response range is 1 to 5")
    func responseRange_isOneToFive() {
        #expect(PostSessionSurvey.minResponse == 1)
        #expect(PostSessionSurvey.maxResponse == 5)
    }
}
