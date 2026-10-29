import Foundation

/// One row of the results table: a snapshot of an item with sortable keys.
struct ResultRow: Identifiable, Sendable {
    let id: UUID
    let name: String
    let conversion: String
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
        name = item.name
        let source = item.source
        let result = item.result
        let from = source?.formatName ?? item.url.pathExtension.uppercased()
        let to = result?.format ?? source.flatMap { OutputPlan.previewFormat(for: $0, options: options) }
        conversion = to.map { "\(from) → \($0.name)" } ?? from

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
            "| Name | Conversion | Dimensions | Old size | New size | % | Status |",
            "|---|---|---|---:|---:|---:|---|",
        ]
        func cell(_ text: String) -> String { text.replacingOccurrences(of: "|", with: "\\|") }
        for row in rows {
            lines.append("| \(cell(row.name)) | \(row.conversion) | \(row.dimensions) | \(Formatting.bytes(row.oldSize)) | "
                + "\(row.newSize.map(Formatting.bytes) ?? "—") | \(row.percent.map(Formatting.percent) ?? "—") | \(row.status) |")
        }
        lines.append("| **Total (\(totals.count) processed)** | | | \(Formatting.bytes(totals.oldSize)) | "
            + "\(Formatting.bytes(totals.newSize)) | \(Formatting.percent(totals.percent)) | |")
        return lines.joined(separator: "\n") + "\n"
    }
}
