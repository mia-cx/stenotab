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
        let legacy = VoiceAssessment(
            summary: "Existing",
            sampleCount: 10,
            sourceEventCount: 10,
            generatedAt: now,
            analyzerVersion: nil
        )
        XCTAssertTrue(
            VoiceAssessmentSchedule.shouldAssess(
                existing: legacy,
                sourceEventCount: 10,
                at: now.addingTimeInterval(60)
            )
        )
    }

    func testLegacyAssessmentWithoutAnalyzerVersionDecodesAndRefreshes() throws {
        let data = Data(
            """
            {
              "summary": "Existing",
              "sampleCount": 10,
              "sourceEventCount": 10,
              "generatedAt": 0
            }
            """.utf8
        )
        let assessment = try JSONDecoder().decode(
            VoiceAssessment.self,
            from: data
        )

        XCTAssertNil(assessment.analyzerVersion)
        XCTAssertTrue(
            VoiceAssessmentSchedule.shouldAssess(
                existing: assessment,
                sourceEventCount: 10,
                at: Date(timeIntervalSinceReferenceDate: 60)
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

    func testAssessmentRecognizesRepeatedBritishEnglishPreferences() {
        let texts = [
            "my favourite colour is green",
            "the centre panel needs more contrast",
            "that behaviour seems intentional",
            "i'll organise the remaining changes",
            "the licence is in the repository"
        ]

        let assessment = VoiceAssessmentAnalyzer.assess(
            texts: texts,
            sourceEventCount: 10,
            at: Date(timeIntervalSince1970: 300)
        )

        XCTAssertTrue(
            assessment?.summary.contains(
                "I usually write in British English"
            ) == true
        )
    }

    func testAssessmentRecognizesRepeatedAmericanEnglishPreferences() {
        let texts = [
            "my favorite color is green",
            "the center panel needs more contrast",
            "that behavior seems intentional",
            "i'll organize the remaining changes",
            "the license is in the repository"
        ]

        let assessment = VoiceAssessmentAnalyzer.assess(
            texts: texts,
            sourceEventCount: 10,
            at: Date(timeIntervalSince1970: 400)
        )

        XCTAssertTrue(
            assessment?.summary.contains(
                "I usually write in American English"
            ) == true
        )
    }

    func testAssessmentDescribesSustainedMixedEnglishSpellingsWithoutChoosing() {
        let texts = [
            "my favourite color is green",
            "the centre panel has odd behavior",
            "i'll organise the license files",
            "my favorite colour is blue",
            "the center panel changed its behaviour",
            "i'll organize the licence files"
        ]

        let assessment = VoiceAssessmentAnalyzer.assess(
            texts: texts,
            sourceEventCount: 10,
            at: Date(timeIntervalSince1970: 500)
        )

        XCTAssertTrue(
            assessment?.summary.contains(
                "I mix British and American English spellings"
            ) == true
        )
        XCTAssertFalse(
            assessment?.summary.contains("I usually write in British English")
                == true
        )
        XCTAssertFalse(
            assessment?.summary.contains("I usually write in American English")
                == true
        )
    }

    func testAssessmentDoesNotGuessDialectFromOneRepeatedSpelling() {
        let texts = [
            "i like that colour",
            "the colour is fine",
            "can we keep this colour?",
            "that colour works",
            "same colour as before"
        ]

        let assessment = VoiceAssessmentAnalyzer.assess(
            texts: texts,
            sourceEventCount: 10,
            at: Date(timeIntervalSince1970: 600)
        )

        XCTAssertFalse(
            assessment?.summary.contains("British English") == true
        )
        XCTAssertFalse(
            assessment?.summary.contains("American English") == true
        )
    }

    func testAssessmentRecognizesSustainedEnglishAndDutchCodeSwitching() {
        let texts = [
            "could you check whether the settings window still opens after "
                + "the latest update and whether every option remains visible?",
            "i think the model download finished successfully and the local "
                + "server is responding normally to completion requests",
            "the autocomplete suggestion looks correctly aligned now and it "
                + "continues on the next line without covering existing text",
            "kun je controleren of het instellingenvenster nog opent na de "
                + "laatste update en of alle opties zichtbaar blijven?",
            "volgens mij is het model helemaal klaar met downloaden en "
                + "reageert de lokale server normaal op aanvullingen",
            "de automatische aanvulling staat nu op de juiste plek en gaat "
                + "netjes verder op de volgende regel"
        ]

        let assessment = VoiceAssessmentAnalyzer.assess(
            texts: texts,
            sourceEventCount: 10,
            at: Date(timeIntervalSince1970: 700)
        )

        XCTAssertTrue(
            assessment?.summary.contains(
                "I switch between English and Dutch"
            ) == true
        )
    }

    func testNonEnglishCognatesDoNotBecomeEnglishDialectEvidence() {
        let texts = [
            "le programme fonctionne correctement sur mon ordinateur et "
                + "toutes les suggestions apparaissent sans délai visible",
            "le centre de la fenêtre contient tous les réglages nécessaires "
                + "pour configurer le modèle local et les raccourcis",
            "la licence du logiciel se trouve dans le dépôt avec la "
                + "documentation complète pour installer cette version",
            "je vais vérifier les autres modifications maintenant avant de "
                + "publier la nouvelle version pour les utilisateurs"
        ]

        let assessment = VoiceAssessmentAnalyzer.assess(
            texts: texts,
            sourceEventCount: 10,
            at: Date(timeIntervalSince1970: 800)
        )

        XCTAssertTrue(
            assessment?.summary.contains("I usually write in French") == true
        )
        XCTAssertFalse(
            assessment?.summary.contains("British English") == true
        )
    }
}
