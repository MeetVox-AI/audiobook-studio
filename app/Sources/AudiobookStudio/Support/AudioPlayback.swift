import AVFoundation
import Foundation

/// One shared audio player for samples, A/B comparisons and finished audiobooks
/// (`AppModel.player`). Playing a new file stops the previous one, so only one thing plays at a time.
@MainActor
@Observable
final class AudioPlayback {
    private(set) var currentURL: URL?
    private(set) var isPlaying = false
    /// User-facing message when a file cannot be played.
    private(set) var errorMessage: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var delegate: FinishDelegate?

    init() {}

    func play(_ url: URL) {
        stop()
        errorMessage = nil
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            let d = FinishDelegate { [weak self] in self?.didFinish() }
            p.delegate = d
            p.prepareToPlay()
            guard p.play() else {
                errorMessage = "This audio file could not be played."
                return
            }
            player = p
            delegate = d
            currentURL = url
            isPlaying = true
        } catch {
            errorMessage = "This audio file could not be played: \(error.localizedDescription)"
        }
    }

    /// Plays `url`, or stops it if it is the file playing now.
    func toggle(_ url: URL) {
        if isPlaying(url) { stop() } else { play(url) }
    }

    func stop() {
        player?.stop()
        player = nil
        delegate = nil
        isPlaying = false
        currentURL = nil
    }

    func isPlaying(_ url: URL) -> Bool { isPlaying && currentURL == url }

    private func didFinish() {
        player = nil
        delegate = nil
        isPlaying = false
        currentURL = nil
    }

    /// AVAudioPlayer calls its delegate on the main thread; the closure hops to the main actor explicitly.
    private final class FinishDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
        let onFinish: @MainActor @Sendable () -> Void
        init(onFinish: @escaping @MainActor @Sendable () -> Void) { self.onFinish = onFinish }

        func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
            let done = onFinish
            Task { @MainActor in done() }
        }

        func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
            let done = onFinish
            Task { @MainActor in done() }
        }
    }
}
