#if canImport(Testing)
import Testing
@testable import ABSPlayer

/// X16: a finished title has nothing left to resume (its saved position is the
/// end), so a deliberate play restarts it from the beginning — but a silent
/// session restore must never reset it.
struct CompletedResumeTests {
    @Test("deliberate play of a finished title restarts")
    func finishedAutoplayRestarts() {
        #expect(PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: true, isFinished: true))
    }

    @Test("silent restore of a finished title does NOT restart")
    func finishedSilentRestoreKeeps() {
        #expect(!PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: false, isFinished: true))
    }

    @Test("an unfinished title resumes (no restart) whether or not autoplay")
    func unfinishedResumes() {
        #expect(!PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: true, isFinished: false))
        #expect(!PlayerCoordinator.resolvesToRestart(explicitRestart: false, autoplay: false, isFinished: false))
    }

    @Test("an explicit restart always restarts")
    func explicitRestartWins() {
        #expect(PlayerCoordinator.resolvesToRestart(explicitRestart: true, autoplay: false, isFinished: false))
    }
}
#endif
