import Foundation

/// One row of the results table: a snapshot of an item with sortable keys.
struct ResultRow: Identifiable, Sendable {
    let id: UUID
    /// The file as it was added.
    let input: String
    /// The file written, or before processing the name it will get (see `outputIsPlanned`).
    let output: String
    let outputIsPlanned: Bool
    let dimensions: String
    let pixelCount: Int
    let oldSize: Int64
    let newSize: Int64?
    let percent: Double?
    let status: String
    let detail: String
    let isError: Bool

    // Sort keys for optional columns: unprocessed rows sort last.
    var newSizeKey: Int64 { newSize ?? .max }
    var percentKey: Double { percent ?? .infinity }

    @MainActor
    init(item: ImageItem, options: ProcessingOptions) {
        id = item.id
        input = item.originalURL.lastPathComponent
        let source = item.source
        let result = item.result
        let to = result?.format ?? source.flatMap { OutputPlan.previewFormat(for: $0, options: options) }
        (output, outputIsPlanned) = Self.output(for: item, format: to, options: options)

        if let source {
            let old = "\(source.pixelWidth)×\(source.pixelHeight)"
            if let w = result?.outputWidth, let h = result?.outputHeight, (w, h) != (source.pixelWidth, source.pixelHeight) {
                dimensions = "\(old) → \(w)×\(h)"
            } else {
                dimensions = old
            }
            pixelCount = source.pixelWidth * source.pixelHeight
            oldSize = source.fileSize
        } else {
            dimensions = "—"
            pixelCount = 0
            oldSize = 0
        }

        if let sizes = item.sizes {
            newSize = sizes.new
            percent = Formatting.change(old: sizes.old, new: sizes.new)
        } else {
            newSize = nil
            percent = nil
        }

        switch item.state {
        case .loading: (status, detail, isError) = ("…", "Reading file", false)
        case .ready: (status, detail, isError) = ("Waiting", "Not processed yet", false)
        case .processing: (status, detail, isError) = ("Processing", "Processing", false)
        case .unsupported: (status, detail, isError) = ("Unsupported", "This file type can't be read.", true)
        case .finished(let r):
            let failed: Bool = if case .failed = r.outcome { true } else { false }
            (status, detail, isError) = (r.statusText, r.detail, failed)
        }
    }

    /// The written file's name, or the name it would get with the current settings.
    @MainActor
    private static func output(for item: ImageItem, format: ImageFormat?, options: ProcessingOptions) -> (String, Bool) {
        switch item.state {
        case .finished(let result):
            switch result.outcome {
            case .written(let url): return (url.lastPathComponent, false)
            case .alreadyOptimal: return ("Unchanged", false)
            default: return ("—", false)
            }
        case .unsupported:
            return ("—", false)
        default:
            guard let format else { return ("—", true) }
            let source = item.originalURL
            let ext = Writer.outputExtension(for: source, format: format)
            let name = options.outputMode == .copy
                ? Writer.copyName(for: source, ext: ext, prefix: options.prefix, suffix: options.suffix)
                : source.deletingPathExtension().appendingPathExtension(ext).lastPathComponent
            return (name, true)
        }
    }
}

/// Summed old/new size over processed rows.
struct ResultTotals: Sendable {
    let count: Int
    let oldSize: Int64
    let newSize: Int64

    var percent: Double { Formatting.change(old: oldSize, new: newSize) }

    @MainActor
    init(items: [ImageItem]) {
        let sizes = items.compactMap(\.sizes)
        count = sizes.count
        oldSize = sizes.reduce(0) { $0 + $1.old }
        newSize = sizes.reduce(0) { $0 + $1.new }
    }
}

enum MarkdownExport {
    /// The results table plus totals, as a Markdown table.
    static func table(rows: [ResultRow], totals: ResultTotals) -> String {
        var lines = [
            "| Input | Output | Dimensions | Old size | New size | % | Status |",
            "|---|---|---|---:|---:|---:|---|",
        ]
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
        for row in rows {
            lines.append("| \(cell(row.input)) | \(cell(row.output)) | \(row.dimensions) | \(Formatting.bytes(row.oldSize)) | "
                + "\(row.newSize.map(Formatting.bytes) ?? "—") | \(row.percent.map(Formatting.percent) ?? "—") | \(row.status) |")
        }
        lines.append("| **Total (\(totals.count) processed)** | | | \(Formatting.bytes(totals.oldSize)) | "
            + "\(Formatting.bytes(totals.newSize)) | \(Formatting.percent(totals.percent)) | |")
        return lines.joined(separator: "\n") + "\n"
    }
}
