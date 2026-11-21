import AppKit
import CaptureCore
import Foundation
import ImageIO

struct ExploreItem: Identifiable {
    let url: URL
    var id: String { url.lastPathComponent }
    var thumbnail: NSImage?
    var captured: Bool
}

/// The viewer tab: the last few exploring photos as a carousel, one shown large.
final class ViewerModel: ObservableObject {
    /// How many exploring photos are kept.
    static let keep = 30

    @Published var items: [ExploreItem] = []
    @Published var selectedID: String?
    /// The large picture for the selected photo, and the quarter turns to display it with.
    @Published var large: (image: CGImage, turns: Int)?
    @Published var loading = false
    @Published var problem: String?

    let library: ExploringLibrary
    private let previews: ARWPreviews?
    private let defaults: UserDefaults
    private var loadToken = UUID()

    init(library: ExploringLibrary, exiftool: ExifTool?, defaults: UserDefaults = .standard) {
        self.library = library
        self.previews = exiftool.map { ARWPreviews(exiftool: $0, library: library) }
        self.defaults = defaults
        if exiftool == nil { problem = "ExifTool was not found; the viewer needs it to read the photos' embedded previews." }
    }

    var selected: ExploreItem? { items.first { $0.id == selectedID } }

    private var capturedNames: Set<String> {
        get { Set(defaults.stringArray(forKey: "capturedExplores") ?? []) }
        set { defaults.set(Array(newValue).suffix(500), forKey: "capturedExplores") }
    }

    /// Re-reads the folder. `selectNewest` is used when a new photo has just arrived.
    func reload(selectNewest: Bool = false) {
        library.prune(keep: Self.keep)
        let captured = capturedNames
        let old = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = library.items().map { url in
            var item = old[url.lastPathComponent] ?? ExploreItem(url: url, thumbnail: nil, captured: false)
            item.captured = captured.contains(url.lastPathComponent)
            return item
        }
        if selectNewest || selected == nil { select(items.last?.id) }
        loadThumbnails()
    }

    func select(_ id: String?) {
        guard id != selectedID || large == nil else { return }
        selectedID = id
        large = nil
        guard let item = selected, let previews else { return }
        let token = UUID()
        loadToken = token
        loading = true
        Task {
            do {
                let (url, turns) = try await previews.full(for: item.url)
                let image = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                }.value
                await MainActor.run {
                    guard self.loadToken == token else { return }
                    self.loading = false
                    if let image { self.large = (image, [1: 0, 3: 2, 6: 1, 8: 3][turns] ?? 0); self.problem = nil }
                    else { self.problem = "Could not read the preview of \(item.url.lastPathComponent)." }
                }
            } catch {
                await MainActor.run {
                    guard self.loadToken == token else { return }
                    self.loading = false
                    self.problem = "\(error)"
                }
            }
        }
    }

    func step(_ delta: Int) {
        guard let i = items.firstIndex(where: { $0.id == selectedID }) else { select(items.last?.id); return }
        let j = min(max(i + delta, 0), items.count - 1)
        select(items[j].id)
    }

    func markCaptured(_ id: String) {
        capturedNames.insert(id)
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].captured = true }
    }

    private func loadThumbnails() {
        guard let previews else { return }
        let missing = items.filter { $0.thumbnail == nil }.map(\.url)
        guard !missing.isEmpty else { return }
        Task {
            // Newest first, so the photo you just took appears first.
            for url in missing.reversed() {
                guard let thumb = try? await previews.thumbnail(for: url), let img = NSImage(contentsOf: thumb) else { continue }
                await MainActor.run {
                    if let i = self.items.firstIndex(where: { $0.url == url }) { self.items[i].thumbnail = img }
                }
            }
        }
    }
}
