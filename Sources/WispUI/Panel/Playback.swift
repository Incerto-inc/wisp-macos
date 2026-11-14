import AppKit
import AVFoundation
import AVKit
import SwiftUI

/// AppKit-backed player chrome. SwiftUI `VideoPlayer` aborts inside menu-bar NSPanels on macOS 26+.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

/// Plays `video.mov` with the separate mic/system tracks kept in sync and individually mutable.
@MainActor
final class SyncedPlaybackController: ObservableObject {
    let videoPlayer = AVPlayer()
    /// Drives transport for Room (mic-only) sessions, which have no video.
    let primaryAudioPlayer = AVPlayer()
    private var micPlayer: AVPlayer?
    private var systemPlayer: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var rateObserver: NSKeyValueObservation?
    private var lastTransport: AVPlayer.TimeControlStatus = .paused

    @Published var micMuted = false { didSet { applyAudio() } }
    @Published var systemMuted = false { didSet { applyAudio() } }
    @Published var micVolume: Float = 1 { didSet { applyAudio() } }
    @Published var systemVolume: Float = 1 { didSet { applyAudio() } }

    func load(files: RecordingFiles) {
        tearDown()

        if let video = files.video {
            let videoItem = AVPlayerItem(url: video)
            videoPlayer.replaceCurrentItem(with: videoItem)
            videoPlayer.isMuted = true
            if let mic = files.mic { micPlayer = AVPlayer(url: mic) }
            if let system = files.system { systemPlayer = AVPlayer(url: system) }
            applyAudio()

            timeObserver = videoPlayer.addPeriodicTimeObserver(
                forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
                queue: .main
            ) { [weak self] time in
                Task { @MainActor in self?.sync(to: time) }
            }
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: videoItem,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.micPlayer?.pause()
                    self?.systemPlayer?.pause()
                }
            }
            rateObserver = videoPlayer.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
                Task { @MainActor in self?.mirrorTransport(player.timeControlStatus) }
            }
            return
        }

        if let mic = files.mic {
            primaryAudioPlayer.replaceCurrentItem(with: AVPlayerItem(url: mic))
            primaryAudioPlayer.isMuted = false
            primaryAudioPlayer.volume = 1
        }
    }

    private func mirrorTransport(_ status: AVPlayer.TimeControlStatus) {
        lastTransport = status
        switch status {
        case .playing:
            micPlayer?.play()
            systemPlayer?.play()
        case .paused, .waitingToPlayAtSpecifiedRate:
            micPlayer?.pause()
            systemPlayer?.pause()
        @unknown default:
            break
        }
    }

    private func sync(to time: CMTime) {
        if lastTransport == .playing {
            micPlayer?.play()
            systemPlayer?.play()
        }
        for player in [micPlayer, systemPlayer].compactMap({ $0 }) {
            if abs(player.currentTime().seconds - time.seconds) > 0.25 {
                player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    private func applyAudio() {
        micPlayer?.isMuted = micMuted
        micPlayer?.volume = micVolume
        systemPlayer?.isMuted = systemMuted
        systemPlayer?.volume = systemVolume
    }

    func tearDown() {
        if let timeObserver {
            videoPlayer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        rateObserver?.invalidate()
        rateObserver = nil
        videoPlayer.pause()
        videoPlayer.replaceCurrentItem(with: nil)
        primaryAudioPlayer.pause()
        primaryAudioPlayer.replaceCurrentItem(with: nil)
        micPlayer?.pause()
        systemPlayer?.pause()
        micPlayer = nil
        systemPlayer = nil
    }
}
