import SwiftUI
import UIKit

// Drop-in replacement for SwiftUI's AsyncImage that fixes the "cover icons frequently don't load"
// problem on the Cloud Play grid. AsyncImage has two fatal flaws for a LazyVGrid of ~5000 cells:
//   1) NO memory cache -- it refetches the image every single time a cell reappears, and
//   2) it CANCELS the in-flight download when a cell is recycled / the view re-renders.
// Fast CDNs (image.api.playstation.com) finish before the cancel; slower ones
// (vulcan.dl.playstation.net, apollo2.dl.playstation.net) get cancelled mid-download (the flood of
// NSURLErrorDomain -999 "cancelled" in the logs) and AsyncImage never retries -> permanent gray
// placeholder.
//
// This version routes all loads through a SHARED loader whose download Tasks are owned by the loader,
// NOT by the view. So when a cell scrolls away the SwiftUI .task is cancelled but the underlying
// download keeps going, lands in the cache, and the next time that cell appears it renders instantly.
// Results are kept in an NSCache (memory) and the URLSession's URLCache (disk), and concurrent
// requests for the same URL are de-duplicated.

enum CachedImagePhase {
    case empty
    case success(Image)
    case failure(Error)
}

actor CloudImageLoader {
    static let shared = CloudImageLoader()

    private let memory: NSCache<NSURL, UIImage>
    private let session: URLSession
    private var inFlight: [URL: Task<UIImage?, Never>] = [:]

    init() {
        memory = NSCache<NSURL, UIImage>()
        memory.countLimit = 600
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: cfg)
    }

    nonisolated func cachedSync(_ url: URL) -> UIImage? {
        // Synchronous memory hit so an already-loaded cover renders with zero flicker on reuse.
        memory.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let img = memory.object(forKey: url as NSURL) { return img }
        if let existing = inFlight[url] { return await existing.value }
        let task = Task<UIImage?, Never> { [session, memory] in
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 30
                let (data, _) = try await session.data(for: request)
                guard let img = UIImage(data: data) else { return nil }
                memory.setObject(img, forKey: url as NSURL)
                return img
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let result = await task.value
        inFlight[url] = nil
        return result
    }
}

struct CachedAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (CachedImagePhase) -> Content

    @State private var phase: CachedImagePhase = .empty

    init(url: URL?, @ViewBuilder content: @escaping (CachedImagePhase) -> Content) {
        self.url = url
        self.content = content
    }

    var body: some View {
        content(phase)
            // .task(id:) re-runs when the URL changes and is cancelled when the cell is recycled --
            // but cancelling THIS only stops us awaiting; the shared loader's download continues and
            // caches, so reappearing cells render instantly instead of restarting/cancelling forever.
            .task(id: url) {
                guard let url else {
                    phase = .empty
                    return
                }
                if let cached = CloudImageLoader.shared.cachedSync(url) {
                    phase = .success(Image(uiImage: cached))
                    return
                }
                if case .success = phase { phase = .empty }
                let img = await CloudImageLoader.shared.image(for: url)
                // The shared download deliberately outlives .task(id:) cancellation (see
                // above), so this continuation can resume for a URL the view no longer
                // shows — don't let the stale result overwrite the newer task's phase.
                guard !Task.isCancelled else { return }
                if let img {
                    phase = .success(Image(uiImage: img))
                } else {
                    phase = .failure(URLError(.cannotDecodeContentData))
                }
            }
    }
}
