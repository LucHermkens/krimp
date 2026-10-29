import SwiftUI

struct ImageGrid: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(model.items) { item in
                    ImageCard(item: item)
                        .contextMenu { ItemMenu(ids: [item.id]) }
                }
            }
            .padding(16)
        }
    }
}

/// Context menu shared by the grid and the table.
struct ItemMenu: View {
    @Environment(AppModel.self) private var model
    let ids: Set<ImageItem.ID>

    var body: some View {
        Button("Reveal in Finder") { model.reveal(ids) }
        Button("Remove from List") { model.remove(ids) }
            .disabled(model.isRunning)
    }
}

private struct ImageCard: View {
    @Environment(AppModel.self) private var model
    let item: ImageItem

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.5))
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(6)
                } else if item.state != .loading {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
                if item.state == .processing || item.state == .loading {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 140)
            .overlay(alignment: .topTrailing) { StatusBadge(item: item).padding(6) }
            .overlay(alignment: .topLeading) {
                if item.source?.isAnimated == true {
                    Badge(text: "Animated → first frame", systemImage: "film")
                        .padding(6)
                        .help("Only the first frame is used")
                }
            }

            Text(item.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.url.path)
            SizeLine(item: item, options: model.settings.options)
        }
    }
}

/// "JPEG · 722 KB" before processing, "WebP · 214 KB (−70%)" after, plus the conversion.
private struct SizeLine: View {
    let item: ImageItem
    let options: ProcessingOptions

    var body: some View {
        VStack(spacing: 2) {
            if let source = item.source {
                if let sizes = item.sizes, let result = item.result {
                    let change = Formatting.change(old: sizes.old, new: sizes.new)
                    let format = result.format?.name ?? source.formatName
                    let delta = Text("(\(Formatting.percent(change)))").foregroundStyle(change > 0 ? .red : .secondary)
                    Text("\(format) · \(Formatting.bytes(sizes.new)) \(delta)")
                        .font(.caption)
                } else {
                    Text("\(source.formatName) · \(Formatting.bytes(source.fileSize))")
                        .font(.caption)
                }
                if let target = item.result?.format ?? OutputPlan.previewFormat(for: source, options: options) {
                    Text("\(source.formatName) → \(target.name)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(" ").font(.caption)
            }
        }
        .monospacedDigit()
    }
}

private struct StatusBadge: View {
    let item: ImageItem

    var body: some View {
        switch item.state {
        case .unsupported:
            Badge(text: "Unsupported", systemImage: "exclamationmark.triangle.fill", tint: .orange)
                .help("This file type can't be read.")
        case .finished(let result):
            switch result.outcome {
            case .written:
                Badge(text: nil, systemImage: "checkmark.circle.fill", tint: .green).help(result.detail)
            case .alreadyOptimal:
                Badge(text: "Already optimal", systemImage: "checkmark.seal", tint: .secondary).help(result.detail)
            case .skipped:
                Badge(text: "Skipped", systemImage: "forward.fill", tint: .secondary).help(result.detail)
            case .unsupported:
                Badge(text: "Unsupported", systemImage: "exclamationmark.triangle.fill", tint: .orange).help(result.detail)
            case .failed:
                Badge(text: "Error", systemImage: "xmark.octagon.fill", tint: .red).help(result.detail)
            }
        default:
            EmptyView()
        }
    }
}

struct Badge: View {
    let text: String?
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).foregroundStyle(tint)
            if let text { Text(text) }
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9), in: Capsule())
    }
}
