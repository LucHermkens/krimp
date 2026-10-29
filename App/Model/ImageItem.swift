import CoreGraphics
import Foundation
import Observation

/// One file in the list.
@MainActor @Observable
final class ImageItem: Identifiable {
    enum State: Equatable {
        case loading
        case ready
        case processing
        case finished(ItemResult)
        case unsupported
    }

    let id = UUID()
    /// Where the source file is (updated when Replace mode renames it).
    var url: URL
    var source: SourceInfo?
    var thumbnail: CGImage?
    var state = State.loading

    /// The file as it was added (Replace mode moves `url` to the output).
    let originalURL: URL

    init(url: URL) {
        self.url = url
        self.originalURL = url
    }

    var name: String { url.lastPathComponent }

    var isPending: Bool { state == .ready }

    var result: ItemResult? {
        if case .finished(let result) = state { return result }
        return nil
    }

    /// The file to show in Finder: the written output if there is one.
    var revealURL: URL {
        if case .written(let output)? = result?.outcome { return output }
        return url
    }

    /// Old and new size when the item counts towards the totals (written or already optimal).
    var sizes: (old: Int64, new: Int64)? {
        guard let source, let result else { return nil }
        switch result.outcome {
        case .written: return result.outputSize.map { (source.fileSize, $0) }
        case .alreadyOptimal: return (source.fileSize, source.fileSize)
        default: return nil
        }
    }
}

extension ItemResult {
    /// Short status for badges and the table.
    var statusText: String {
        switch outcome {
        case .written: "✓"
        case .alreadyOptimal: "Already optimal"
        case .skipped(let reason): reason == "Stopped" ? "Stopped" : "Skipped"
        case .unsupported: "Unsupported"
        case .failed: "Error"
        }
    }

    /// Longer explanation for tooltips.
    var detail: String {
        switch outcome {
        case .written(let url): "Saved as \(url.lastPathComponent)"
        case .alreadyOptimal: "The result wasn't smaller, so the original was left untouched."
        case .skipped(let reason): "Skipped: \(reason)"
        case .unsupported: "This file type can't be read."
        case .failed(let message): message
        }
    }
}

enum Formatting {
    static func bytes(_ count: Int64) -> String {
        count.formatted(.byteCount(style: .file))
    }

    /// "−70%" / "+12%", with a real minus sign.
    static func percent(_ value: Double) -> String {
        let rounded = Int(value.rounded())
        if rounded == 0 { return "0%" }
        return rounded < 0 ? "−\(-rounded)%" : "+\(rounded)%"
    }

    static func change(old: Int64, new: Int64) -> Double {
        old > 0 ? (Double(new) - Double(old)) / Double(old) * 100 : 0
    }
}
