import XCTest
@testable import CompletionCore

final class VoiceAssessmentTests: XCTestCase {
    func testScheduleWaitsForEnoughDataAndThenUsesBatchOrDailyCadence() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(
            VoiceAssessmentSchedule.shouldAssess(
                existing: nil,
                sourceEventCount: 9,
                at: now
            )
        )
        XCTAssertTrue(
            VoiceAssessmentSchedule.shouldAssess(
                existing: nil,
                sourceEventCount: 10,
                at: now
            )
        )
        let existing = VoiceAssessment(
            summary: "Existing",
            sampleCount: 10,
            sourceEventCount: 10,
            generatedAt: now
        )
        XCTAssertFalse(
            VoiceAssessmentSchedule.shouldAssess(
                existing: existing,
                sourceEventCount: 15,
                at: now.addingTimeInterval(60)
            )
        )
        XCTAssertTrue(
            VoiceAssessmentSchedule.shouldAssess(
                existing: existing,
                sourceEventCount: 15,
                at: now.addingTimeInterval(24 * 60 * 60)
            )
        )
        XCTAssertTrue(
            VoiceAssessmentSchedule.shouldAssess(
                existing: existing,
                sourceEventCount: 35,
                at: now.addingTimeInterval(60)
            )
        )
    }

    func testAssessmentSummarizesObservableWritingTraitsInFirstPerson() {
        let texts = [
            "yeah that's fixed now",
            "can you open the pullRequest?",
            "i don't think that's right?",
            "what's the llama.cpp status?",
            "yep that's good",
            "could you check OAuthToken?",
            "i'll do that later",
            "does SwiftUI still do this?",
            "nah that's fine",
            "can we ship it?"
        ]

        let assessment = VoiceAssessmentAnalyzer.assess(
            texts: texts,
            sourceEventCount: 10,
            at: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(assessment?.sampleCount, 10)
        XCTAssertTrue(
            assessment?.summary.contains("short, direct") == true
        )
        XCTAssertTrue(
            assessment?.summary.contains("start casual writing in lowercase")
                == true
        )
        XCTAssertTrue(
            assessment?.summary.contains("contractions frequently") == true
        )
        XCTAssertTrue(
            assessment?.summary.contains("direct questions") == true
        )
        XCTAssertTrue(
            assessment?.summary.contains("technical terms") == true
        )
    }
}
