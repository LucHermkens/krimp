import SwiftUI

struct ResultsTable: View {
    @Environment(AppModel.self) private var model
    @State private var sortOrder = [KeyPathComparator(\ResultRow.input, comparator: .localizedStandard)]
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        let rows = model.rows().sorted(using: sortOrder)
        VStack(spacing: 0) {
            Table(rows, selection: $model.selection, sortOrder: $sortOrder) {
                TableColumn("Input", value: \.input, comparator: .localizedStandard) { row in
                    Text(row.input).lineLimit(1).truncationMode(.middle).help(row.input)
                }
                .width(min: 100, ideal: 160)
                TableColumn("Output", value: \.output, comparator: .localizedStandard) { row in
                    Text(row.output)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(row.outputIsPlanned ? .secondary : .primary)
                        .help(row.outputIsPlanned ? "Will be saved as \(row.output)" : row.output)
                }
                .width(min: 100, ideal: 160)
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
            .focused($focused)
            // NSTableView ignores Backspace, so handle the delete keys here.
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard !model.selection.isEmpty, !model.isRunning else { return .ignored }
                model.removeSelection()
                return .handled
            }
            .onKeyPress(.space) {
                model.togglePreview()
                return .handled
            }
            .onDeleteCommand { model.removeSelection() }
            .onAppear { focused = true }
            // The table doesn't report clicks, so treat a newly selected row as the last clicked.
            .onChange(of: model.selection) { old, new in
                let added = new.subtracting(old)
                if added.count == 1 {
                    model.focusedItem = added.first
                } else if let focused = model.focusedItem, !new.contains(focused) {
                    model.focusedItem = new.count == 1 ? new.first : nil
                }
            }
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
