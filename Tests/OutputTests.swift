import Foundation
import Testing

/// A FileManager whose "Trash" is a folder we control, or that has no Trash at all.
final class FakeTrashFileManager: FileManager, @unchecked Sendable {
    let trash: URL?
    private(set) var trashed: [URL] = []

    init(trash: URL?) {
        self.trash = trash
        super.init()
    }

    override func trashItem(at url: URL, resultingItemURL outResultingURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        guard let trash else { throw CocoaError(.featureUnsupported) }
        let target = trash.appendingPathComponent(url.lastPathComponent)
        try moveItem(at: url, to: target)
        trashed.append(target)
        outResultingURL?.pointee = target as NSURL
    }
}

@Suite struct OutputTests {
    let data = Data("new contents".utf8)

    private func setUp(_ name: String = "photo.png") throws -> (source: URL, trash: URL) {
        let source = try Fixtures.copy("graphics/poster.png", as: name)
        let trash = source.deletingLastPathComponent().appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        return (source, trash)
    }

    @Test func replaceMovesOriginalToTrash() async throws {
        let (source, trash) = try setUp()
        let original = try Data(contentsOf: source)
        let fm = FakeTrashFileManager(trash: trash)
        let output = try await Writer.replace(data, source: source, format: .png, confirmPermanent: { _ in false }, fileManager: fm)
        #expect(output == source)
        #expect(try Data(contentsOf: output) == data)
        #expect(try Data(contentsOf: trash.appendingPathComponent("photo.png")) == original)
    }

    @Test func replaceWithNewFormatChangesExtension() async throws {
        let (source, trash) = try setUp()
        let fm = FakeTrashFileManager(trash: trash)
        let output = try await Writer.replace(data, source: source, format: .webp, confirmPermanent: { _ in false }, fileManager: fm)
        #expect(output.lastPathComponent == "photo.webp")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(fm.trashed.count == 1)
    }

    @Test func replaceNeverOverwritesAnotherFile() async throws {
        let (source, trash) = try setUp()
        let existing = source.deletingPathExtension().appendingPathExtension("webp")
        try Data("keep me".utf8).write(to: existing)
        let output = try await Writer.replace(data, source: source, format: .webp, confirmPermanent: { _ in false },
                                              fileManager: FakeTrashFileManager(trash: trash))
        #expect(output.lastPathComponent == "photo-2.webp")
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }

    @Test func noTrashAsksAndCanDecline() async throws {
        let (source, _) = try setUp()
        let original = try Data(contentsOf: source)
        let asked = Asked()
        await #expect(throws: WriteError.self) {
            try await Writer.replace(data, source: source, format: .png, confirmPermanent: { _ in await asked.mark(); return false },
                                     fileManager: FakeTrashFileManager(trash: nil))
        }
        #expect(await asked.count == 1)
        #expect(try Data(contentsOf: source) == original)
        // No temp files left next to the original.
        let names = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
        #expect(Set(names) == ["photo.png", "Trash"])
    }

    @Test func noTrashReplacesPermanentlyWhenConfirmed() async throws {
        let (source, _) = try setUp()
        let output = try await Writer.replace(data, source: source, format: .png, confirmPermanent: { _ in true },
                                              fileManager: FakeTrashFileManager(trash: nil))
        #expect(try Data(contentsOf: output) == data)
    }

    @Test func diskErrorsArePerItem() async throws {
        // A folder we can't write to: copy mode fails for this item only.
        let (source, _) = try setUp()
        let dir = source.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        let info = try Decode.probe(source)
        let result = await Pipeline.process(info, options: options { $0.outputMode = .copy; $0.format = .jpeg }) { _ in false }
        guard case .failed(let message) = result.outcome else {
            Issue.record("expected failure, got \(result.outcome)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func formatChangeThatGrowsIsWrittenAnyway() async throws {
        // A 285-byte GIF becomes a larger TIFF: written, because the format change was asked for.
        let url = try Fixtures.copy("pipeline/animated.gif")
        let info = try Decode.probe(url)
        let result = await Pipeline.process(info, options: options { $0.outputMode = .copy; $0.format = .tiff }) { _ in false }
        guard case .written = result.outcome else {
            Issue.record("expected a written file, got \(result.outcome)")
            return
        }
        #expect(try #require(result.outputSize) > info.fileSize)
    }

    @MainActor
    @Test func stopLeavesUnstartedItemsPending() async throws {
        let model = AppModel()
        model.settings.outputMode = .copy
        model.settings.format = .avif
        defer { UserDefaults.standard.removeObject(forKey: "outputMode"); UserDefaults.standard.removeObject(forKey: "format") }
        let dir = try Fixtures.copy("photos/kodim03.png").deletingLastPathComponent()
        for i in 1...5 {
            try FileManager.default.copyItem(at: dir.appendingPathComponent("kodim03.png"),
                                             to: dir.appendingPathComponent("copy\(i).png"))
        }
        model.add([dir])
        try await waitUntil { model.items.count == 6 && model.items.allSatisfy { $0.state == .ready } }

        model.start()
        #expect(model.isRunning)
        try await waitUntil { model.items.count { $0.state == .processing } > 0 }
        #expect(model.items.count { $0.state == .processing } <= AppModel.maxInFlight)
        model.stop()
        try await waitUntil { !model.isRunning }

        #expect(model.items.allSatisfy { $0.state != .processing })
        #expect(model.items.count(where: \.isPending) >= 4)
    }

    @MainActor
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

actor Asked {
    var count = 0
    func mark() { count += 1 }
}
