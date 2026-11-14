import CoreGraphics
import Foundation
import WispApplication
import WispDomain

/// Thumbnails for whatever the panel currently shows. Refreshes only while the panel is visible.
@MainActor
public final class ThumbnailStore: ObservableObject {
    @Published public private(set) var images: [CaptureSourceID: CGImage] = [:]

    private let provider: CaptureThumbnailProvider?
    private var loop: Task<Void, Never>?

    public init(provider: CaptureThumbnailProvider?) {
        self.provider = provider
    }

    public func image(for id: CaptureSourceID?) -> CGImage? {
        id.flatMap { images[$0] }
    }

    /// Repeatedly refreshes the ids returned by `ids` (re-read each round) until `stop()`.
    func startLive(interval: Duration = .seconds(1.5), ids: @escaping @MainActor () -> [CaptureSourceID]) {
        guard provider != nil else { return }
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(ids())
                try? await Task.sleep(for: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Cards are about 165 pt wide, so 340 px covers Retina.
    static let pixelSize = 340
    /// Images not shown right now are kept (switching views must not blank the cards) until
    /// there are more than this many; each is 0.2–0.4 MB.
    static let keptImages = 48

    func refresh(_ ids: [CaptureSourceID]) async {
        guard let provider else { return }
        if images.count > Self.keptImages {
            let wanted = Set(ids)
            for id in images.keys where !wanted.contains(id) {
                images[id] = nil
            }
        }
        for id in ids {
            if Task.isCancelled { return }
            if let image = await provider.thumbnail(for: id, maxPixelSize: Self.pixelSize) {
                images[id] = image
            }
        }
    }

    /// Snapshot tool only: show prepared images without a provider.
    func preset(_ images: [CaptureSourceID: CGImage]) {
        self.images = images
    }
}
