import SwiftUI

struct ResultsTable: View {
    @Environment(AppModel.self) private var model
    @State private var selection = Set<ImageItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\ResultRow.name, comparator: .localizedStandard)]

    var body: some View {
        let rows = model.rows().sorted(using: sortOrder)
        VStack(spacing: 0) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name, comparator: .localizedStandard) { row in
                    Text(row.name).lineLimit(1).truncationMode(.middle).help(row.name)
                }
                .width(min: 110, ideal: 170)
                TableColumn("Conversion", value: \.conversion)
                    .width(min: 80, ideal: 100)
                TableColumn("Dimensions", value: \.pixelCount) { row in
                    Text(row.dimensions)
                }
                .width(min: 80, ideal: 150)
                TableColumn("Old size", value: \.oldSize) { row in
                    Text(Formatting.bytes(row.oldSize)).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 66)
                TableColumn("New size", value: \.newSizeKey) { row in
                    Text(row.newSize.map(Formatting.bytes) ?? "—").frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 56, ideal: 66)
                TableColumn("%", value: \.percentKey) { row in
                    Text(row.percent.map(Formatting.percent) ?? "—")
                        .foregroundStyle((row.percent ?? 0) > 0 ? .red : .primary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 40, ideal: 48)
                TableColumn("Status", value: \.status) { row in
                    Text(row.status)
                        .foregroundStyle(row.isError ? .red : row.status == "✓" ? .green : .secondary)
                        .help(row.detail)
                }
                .width(min: 60, ideal: 100)
            }
            .monospacedDigit()
            .contextMenu(forSelectionType: ImageItem.ID.self) { ids in
                if !ids.isEmpty {
                    ItemMenu(ids: ids)
                    Divider()
                }
                Button("Copy Results as Markdown") { model.copyMarkdown(rows: rows) }
            }

            Divider()
            TotalsRow(totals: model.totals)
        }
    }
}

/// Pinned below the table: summed sizes over processed items.
private struct TotalsRow: View {
    let totals: ResultTotals

    var body: some View {
        HStack(spacing: 16) {
            Text(totals.count == 1 ? "Total · 1 processed" : "Total · \(totals.count) processed")
                .fontWeight(.semibold)
            Spacer()
            if totals.count > 0 {
                LabeledContent("Old", value: Formatting.bytes(totals.oldSize))
                LabeledContent("New", value: Formatting.bytes(totals.newSize))
                Text(Formatting.percent(totals.percent))
                    .fontWeight(.semibold)
                    .foregroundStyle(totals.percent > 0 ? .red : .primary)
            } else {
                Text("Nothing processed yet").foregroundStyle(.secondary)
            }
        }
        .monospacedDigit()
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
