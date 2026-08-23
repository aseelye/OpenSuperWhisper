import Foundation
import XCTest
@testable import OpenSuperWhisper

final class InputUIPresentationTests: XCTestCase {
    func testPresentationTableCoversEveryOperationPhase() {
        let phases: [TranscriptionOperationPhase] = [
            .preparing,
            .recording,
            .finalizingAudio,
            .exporting,
            .uploading(part: 1, total: 3),
            .retrying(attempt: 1, maximum: 2),
            .transcribing,
            .saving,
            .cancelling
        ]

        for phase in phases {
            let presentation = DictationSessionPresentation(snapshot(phase: phase))
            XCTAssertFalse(presentation.phaseText.isEmpty)
            XCTAssertFalse(presentation.accessibilityLabel.isEmpty)
            XCTAssertEqual(presentation.isBusy, true)
        }
    }

    func testImportedUploadWithoutFractionIsIndeterminate() {
        let snapshot = snapshot(
            phase: .uploading(part: nil, total: nil, fraction: nil),
            source: .importedFile
        )
        let presentation = DictationSessionPresentation(snapshot)

        XCTAssertTrue(presentation.isIndeterminate)
        XCTAssertNil(presentation.progress)
        XCTAssertEqual(presentation.phaseText, "Uploading")
    }

    func testExactUploadAndRetryProgressRemainDeterminate() {
        let upload = DictationSessionPresentation(snapshot(
            phase: .uploading(part: 2, total: 4, fraction: nil)
        ))
        XCTAssertFalse(upload.isIndeterminate)
        XCTAssertEqual(upload.progress, 0.5)

        let retry = DictationSessionPresentation(snapshot(
            phase: .retrying(attempt: 2, maximum: 3)
        ))
        XCTAssertFalse(retry.isIndeterminate)
        XCTAssertEqual(retry.progress, 1.0 / 3.0)
    }

    func testCancellingHasNoReplacementActionAndVisibleLabel() {
        let presentation = DictationSessionPresentation(snapshot(phase: .cancelling))
        XCTAssertEqual(presentation.action, .none)
        XCTAssertFalse(presentation.canCancel)
        XCTAssertEqual(presentation.accessibilityLabel, "Cancelling")
        XCTAssertEqual(presentation.phaseText, "Cancelling")
    }

    func testTerminalOutcomeOwnsPresentationActionAndLabel() {
        let presentation = DictationSessionPresentation(snapshot(
            phase: .saving,
            outcome: .failed
        ))

        XCTAssertEqual(presentation.action, .none)
        XCTAssertEqual(presentation.phaseText, "Failed")
        XCTAssertEqual(presentation.accessibilityLabel, "Transcription failed")
        XCTAssertFalse(presentation.isBusy)
        XCTAssertFalse(presentation.isIndeterminate)
    }

    private func snapshot(
        phase: TranscriptionOperationPhase,
        source: SessionOperationSource = .fileDrop,
        outcome: DictationSessionTerminalOutcome? = nil
    ) -> DictationSessionSnapshot {
        DictationSessionSnapshot(
            token: SessionOperationToken(UUID()),
            source: source,
            backend: .appleSpeech,
            phase: phase,
            progress: 0,
            duration: 0,
            interimText: "",
            warning: nil,
            outcome: outcome,
            isBusy: outcome == nil,
            canCancel: outcome == nil && phase != .cancelling,
            controlAction: phase == .recording ? .stop : (phase == .cancelling ? .none : .cancel),
            accessibilityLabel: phase == .cancelling ? "Cancelling" : "Cancel operation",
            presentationOwner: .fileDrop
        )
    }
}
