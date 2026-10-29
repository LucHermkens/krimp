import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var isTargeted = false

    var body: some View {
        @Bindable var settings = model.settings
        Group {
            if model.items.isEmpty {
                EmptyState()
            } else if settings.viewMode == .grid {
                ImageGrid()
            } else {
                ResultsTable()
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return !urls.isEmpty
        } isTargeted: { isTargeted = $0 }
        .inspector(isPresented: .constant(true)) {
            InspectorView()
                .inspectorColumnWidth(min: 280, ideal: 300, max: 380)
                .interactiveDismissDisabled()
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Add Images…", systemImage: "plus") { model.showImporter = true }
                    .help("Add images (⌘O)")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $settings.viewMode) {
                    Label("Grid", systemImage: "square.grid.2x2").tag(ViewMode.grid)
                    Label("Table", systemImage: "list.bullet").tag(ViewMode.table)
                }
                .pickerStyle(.segmented)
                .help("Show thumbnails or the results table")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Clear List", systemImage: "trash") { model.clear() }
                    .disabled(model.items.isEmpty || model.isRunning)
                    .help("Remove all images from the list")
            }
        }
        .fileImporter(isPresented: Bindable(model).showImporter, allowedContentTypes: Decode.readableTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
        .quickLookPreview(Bindable(model).previewURL)
        .navigationTitle("Krimp")
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ContentUnavailableView {
            Label("Drop images here", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("JPEG, PNG, HEIC, WebP, AVIF, GIF, TIFF, RAW, SVG and more.")
        } actions: {
            Button("Open…") { model.showImporter = true }
        }
    }
}
