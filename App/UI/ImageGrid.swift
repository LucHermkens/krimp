import SwiftUI

struct ImageGrid: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    /// Where a ⇧-click or ⇧-arrow range starts.
    @State private var anchor: ImageItem.ID?
    @State private var width: CGFloat = 0

    private static let minColumnWidth: CGFloat = 150
    private static let spacing: CGFloat = 16
    private static let padding: CGFloat = 16
    private let columns = [GridItem(.adaptive(minimum: minColumnWidth, maximum: 220), spacing: spacing)]

    /// Columns the adaptive grid lays out at the current width.
    private var columnCount: Int {
        max(1, Int((width - 2 * Self.padding + Self.spacing) / (Self.minColumnWidth + Self.spacing)))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(model.items) { item in
                        ImageCard(item: item, isSelected: model.selection.contains(item.id))
                            .contentShape(Rectangle())
                            .onTapGesture { select(item.id) }
                            .contextMenu { ItemMenu(ids: menuTargets(for: item.id)) }
                            .id(item.id)
                    }
                }
                .padding(Self.padding)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .contentShape(Rectangle())
            .onTapGesture {
                model.selection.removeAll()
                focused = true
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                let step = switch press.key {
                case .leftArrow: -1
                case .rightArrow: 1
                case .upArrow: -columnCount
                default: columnCount
                }
                guard let id = move(by: step, extend: press.modifiers.contains(.shift)) else { return .ignored }
                proxy.scrollTo(id)
                return .handled
            }
            .onKeyPress(.space) {
                model.togglePreview()
                return .handled
            }
            .onKeyPress(keys: [.delete, .deleteForward]) { _ in
                guard !model.selection.isEmpty, !model.isRunning else { return .ignored }
                model.removeSelection()
                return .handled
            }
            .onDeleteCommand { model.removeSelection() }
            .onAppear { focused = true }
        }
    }

    /// Click selects one item, ⌘-click toggles, ⇧-click extends from the last clicked item.
    private func select(_ id: ImageItem.ID) {
        focused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if model.selection.remove(id) == nil { model.selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let from = index(of: anchor), let to = index(of: id) {
            model.selection.formUnion(model.items[min(from, to)...max(from, to)].map(\.id))
        } else {
            model.selection = [id]
            anchor = id
        }
        model.focusedItem = id
    }

    /// Moves the selection `step` items (clamped to the list) and selects it; with `extend` the
    /// selection becomes the range from the anchor. Returns the newly focused item.
    private func move(by step: Int, extend: Bool) -> ImageItem.ID? {
        guard !model.items.isEmpty else { return nil }
        let current = model.focusedItem.flatMap(index(of:))
            ?? model.items.indices.last { model.selection.contains(model.items[$0].id) }
        let target: Int
        if let current {
            target = min(max(current + step, 0), model.items.count - 1)
        } else {
            target = step < 0 ? model.items.count - 1 : 0
        }
        let id = model.items[target].id
        if extend, let anchorIndex = (anchor ?? model.focusedItem).flatMap(index(of:)) ?? current {
            model.selection = Set(model.items[min(anchorIndex, target)...max(anchorIndex, target)].map(\.id))
            if anchor == nil { anchor = model.items[anchorIndex].id }
        } else {
            model.selection = [id]
            anchor = id
        }
        model.focusedItem = id
        return id
    }

    private func index(of id: ImageItem.ID) -> Int? {
        model.items.firstIndex { $0.id == id }
    }

    /// Right-clicking a selected item acts on the whole selection, like Finder.
    private func menuTargets(for id: ImageItem.ID) -> Set<ImageItem.ID> {
        model.selection.contains(id) ? model.selection : [id]
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
    let isSelected: Bool
    @State private var isHovered = false

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
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .overlay(alignment: .bottomTrailing) { StatusBadge(item: item).padding(6) }
            .overlay(alignment: .topTrailing) {
                if isHovered && item.state != .processing && !model.isRunning {
                    Button("Remove from List", systemImage: "trash") { model.remove([item.id]) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(5)
                        .background(Color(nsColor: .windowBackgroundColor).opacity(0.9), in: Circle())
                        .padding(6)
                        .help("Remove from list")
                }
            }
            .onHover { isHovered = $0 }
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
