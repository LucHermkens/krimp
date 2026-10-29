import SwiftUI

struct InspectorView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    ResizeCard()
                    FormatCard()
                    OutputCard()
                }
                .padding(12)
            }
            .disabled(model.isRunning)
            Divider()
            ActionButton()
                .padding(12)
        }
    }
}

/// A rounded group box with a title, subtitle and an optional header toggle.
private struct Card<Content: View>: View {
    let title: String
    let subtitle: String
    var isOn: Binding<Bool>?
    @ViewBuilder var content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let isOn {
                        Toggle(title, isOn: isOn)
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.small)
                    }
                }
                if isOn?.wrappedValue ?? true {
                    content
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ResizeCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        let unit = settings.resizeMode == .percentage ? "%" : "px"
        Card(title: "Resize",
             subtitle: settings.resizeEnabled ? "\(settings.resizeMode.title) · \(settings.resizeValue) \(unit)" : "Keep dimensions",
             isOn: $settings.resizeEnabled) {
            Picker("Mode", selection: $settings.resizeMode) {
                ForEach(ResizeMode.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                TextField("Size", value: $settings.resizeValue, format: .number.grouping(.never))
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                Text(unit).foregroundStyle(.secondary)
                Spacer()
            }
            .onChange(of: settings.resizeValue) { _, value in
                let clamped = min(max(value, 1), settings.resizeMode == .percentage ? 1000 : 100_000)
                if clamped != value { settings.resizeValue = clamped }
            }
            Text("Images are never enlarged, except SVGs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FormatCard: View {
    @Environment(AppModel.self) private var model

    private var choices: [FormatChoice] {
        FormatChoice.allCases.filter { $0 != .avif || Core.features.contains(.avif) }
    }

    var body: some View {
        @Bindable var settings = model.settings
        let target = settings.format == .same ? nil : ImageFormat(rawValue: settings.format.rawValue)
        let lossless = target.map { !$0.usesQuality } ?? false
        Card(title: "Format", subtitle: subtitle, isOn: $settings.formatEnabled) {
            Picker("Format", selection: $settings.format) {
                ForEach(choices) { choice in
                    Text(choice.title).tag(choice)
                    if choice == .same { Divider() }
                }
            }
            HStack {
                Text("Quality")
                Slider(value: Binding(get: { Double(settings.quality) }, set: { settings.quality = Int($0.rounded()) }),
                       in: 1...100, step: 1)
                    .disabled(lossless)
                Text(lossless ? "Lossless" : "\(settings.quality)%")
                    .monospacedDigit()
                    .foregroundStyle(lossless ? .secondary : .primary)
                    .frame(width: 58, alignment: .trailing)
            }
            if settings.format == .jpeg {
                Toggle("Progressive", isOn: $settings.progressive)
            }
            if settings.format == .png || settings.format == .same {
                Toggle("Max effort for PNG (slow)", isOn: $settings.pngMaxEffort)
                    .help("Uses Zopfli: usually a few percent smaller, but many times slower")
            }
        }
    }

    private var subtitle: String {
        let settings = model.settings
        guard settings.formatEnabled else { return "Keep format and quality" }
        let name = settings.format == .same ? "Same format" : settings.format.title
        switch settings.format {
        case .tiff, .svg: return "\(name) · lossless"
        default: return settings.quality == 100 ? "\(name) · lossless where possible" : "\(name) · quality \(settings.quality)%"
        }
    }
}

private struct OutputCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Card(title: "Output",
             subtitle: settings.outputMode == .replace ? "Originals go to the Trash" : "Saved next to the originals") {
            Picker("Output", selection: $settings.outputMode) {
                ForEach(OutputMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if settings.outputMode == .copy {
                Grid(alignment: .leading, verticalSpacing: 6) {
                    GridRow {
                        Text("Prefix")
                        TextField("None", text: $settings.prefix)
                    }
                    GridRow {
                        Text("Suffix")
                        TextField("None", text: $settings.suffix)
                    }
                }
                if !settings.affixesValid {
                    Label("Can’t contain / or :", systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("photo.jpg → \(Writer.copyName(for: URL(fileURLWithPath: "/photo.jpg"), ext: previewExtension, prefix: settings.prefix, suffix: settings.suffix))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("Skip if larger", isOn: $settings.skipIfLarger)
                .help("If re-encoding in the same format doesn’t make a file smaller, keep the original")
        }
    }

    private var previewExtension: String {
        let settings = model.settings
        guard settings.formatEnabled, settings.format != .same,
              let format = ImageFormat(rawValue: settings.format.rawValue) else { return "jpg" }
        return format.fileExtension
    }
}

private struct ActionButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            if model.isRunning {
                Button(role: .cancel) { model.stop() } label: {
                    Text("Stop").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            } else {
                Button { model.start() } label: {
                    Text(model.actionTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(model.actionHint != nil)
                if let hint = model.actionHint {
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
