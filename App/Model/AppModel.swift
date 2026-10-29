import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import os

/// The file list and the batch runner.
@MainActor @Observable
final class AppModel {
    let settings = Settings()
    private(set) var items: [ImageItem] = []
    private(set) var isRunning = false
    var showImporter = false
    /// Shared by the grid and the table.
    var selection = Set<ImageItem.ID>()

    @ObservationIgnored private var runTask: Task<Void, Never>?

    /// Items processed at the same time. The encoders parallelise internally.
    static let maxInFlight = 2

    var pendingCount: Int { items.count(where: \.isPending) }

    // MARK: - Adding and removing

    func add(_ urls: [URL]) {
        let known = Set(items.map { $0.url.standardizedFileURL })
        var seen = known
        for url in Self.expand(urls) where seen.insert(url.standardizedFileURL).inserted {
            let item = ImageItem(url: url)
            items.append(item)
            load(item)
        }
    }

    func remove(_ ids: Set<ImageItem.ID>) {
        items.removeAll { ids.contains($0.id) && $0.state != .processing }
        selection.formIntersection(items.map(\.id))
    }

    func removeSelection() {
        remove(selection)
    }

    func clear() {
        guard !isRunning else { return }
        items.removeAll()
        selection.removeAll()
    }

    func item(_ id: ImageItem.ID) -> ImageItem? {
        items.first { $0.id == id }
    }

    /// Files as given; folders are searched (recursively) for images.
    private static func expand(_ urls: [URL]) -> [URL] {
        var files: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else {
                files.append(url)
                continue
            }
            let enumerator = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let child = enumerator?.nextObject() as? URL {
                if Decode.isReadable(child) { files.append(child) }
            }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    private func load(_ item: ImageItem) {
        let url = item.url, id = item.id
        Task {
            let loaded = await Self.probe(url)
            guard let item = self.item(id) else { return }
            item.thumbnail = loaded.thumbnail
            if let source = loaded.source {
                item.source = source
                item.state = .ready
            } else {
                item.state = .unsupported
            }
        }
    }

    private struct Loaded: @unchecked Sendable {
        var source: SourceInfo?
        var thumbnail: CGImage?
    }

    @concurrent
    private static func probe(_ url: URL) async -> Loaded {
        guard Decode.isReadable(url), let source = try? Decode.probe(url) else { return Loaded() }
        return Loaded(source: source, thumbnail: Decode.thumbnail(for: url))
    }

    // MARK: - Processing

    func start() {
        guard !isRunning, settings.resizeEnabled || settings.formatEnabled, settings.affixesValid else { return }
        let options = settings.options
        let queue = items.filter(\.isPending)
        guard !queue.isEmpty else { return }
        isRunning = true

        runTask = Task {
            await withTaskGroup(of: (ImageItem.ID, ItemResult).self) { group in
                var next = 0
                @MainActor func launch(_ item: ImageItem, in group: inout TaskGroup<(ImageItem.ID, ItemResult)>) {
                    guard let source = item.source else { return }
                    item.state = .processing
                    let id = item.id
                    group.addTask {
                        (id, await Pipeline.process(source, options: options, confirmPermanentReplace: Self.confirmPermanentDelete))
                    }
                }
                while next < min(Self.maxInFlight, queue.count) {
                    launch(queue[next], in: &group)
                    next += 1
                }
                for await (id, result) in group {
                    self.finish(id, with: result, mode: options.outputMode)
                    if !Task.isCancelled && next < queue.count {
                        launch(queue[next], in: &group)
                        next += 1
                    }
                }
            }
            self.isRunning = false
            self.runTask = nil
            self.settings.viewMode = .table
        }
    }

    func stop() {
        runTask?.cancel()
    }

    private func finish(_ id: ImageItem.ID, with result: ItemResult, mode: OutputMode) {
        guard let item = item(id) else { return }
        if result.outcome == .skipped("Stopped") {
            item.state = .ready  // can be run again
            return
        }
        item.state = .finished(result)
        if mode == .replace, case .written(let url) = result.outcome {
            item.url = url
        }
    }

    /// Asked when the original can't go to the Trash (e.g. a volume without one).
    nonisolated static func confirmPermanentDelete(_ url: URL) async -> Bool {
        await MainActor.run {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(url.lastPathComponent)” can’t be moved to the Trash"
            alert.informativeText = "This volume has no Trash. Replace the original permanently? This can’t be undone."
            alert.addButton(withTitle: "Skip")
            alert.addButton(withTitle: "Replace Permanently").hasDestructiveAction = true
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    // MARK: - Results

    func rows() -> [ResultRow] {
        let options = settings.options
        return items.map { ResultRow(item: $0, options: options) }
    }

    var totals: ResultTotals { ResultTotals(items: items) }

    func copyMarkdown(rows: [ResultRow]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(MarkdownExport.table(rows: rows, totals: totals), forType: .string)
    }

    func reveal(_ ids: Set<ImageItem.ID>) {
        let urls = items.filter { ids.contains($0.id) }.map(\.revealURL)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// The primary button's title.
    var actionTitle: String {
        let n = pendingCount
        let count = n == 0 ? "" : "\(n) "
        if settings.outputMode == .copy { return n == 1 ? "Save 1 Copy" : "Save \(count)Copies" }
        let images = n == 1 ? "Image" : "Images"
        return settings.formatEnabled ? "Compress \(count)\(images)" : "Resize \(count)\(images)"
    }

    /// Why the primary button is disabled, if it is.
    var actionHint: String? {
        if !settings.resizeEnabled && !settings.formatEnabled { return "Turn on Resize or Format" }
        if !settings.affixesValid { return "Prefix and suffix can’t contain / or :" }
        if pendingCount == 0 { return items.isEmpty ? "Add images to get started" : "Add more images to process" }
        return nil
    }
}
