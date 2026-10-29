import Foundation
import Observation

enum ResizeMode: String, CaseIterable, Identifiable, Sendable {
    case width, height, longestEdge, percentage

    var id: Self { self }

    var title: String {
        switch self {
        case .width: "Width"
        case .height: "Height"
        case .longestEdge: "Longest edge"
        case .percentage: "Percentage"
        }
    }
}

/// The format popup. `.same` resolves per item (see `OutputPlan`).
enum FormatChoice: String, CaseIterable, Identifiable, Sendable {
    case same, jpeg, png, webp, avif, gif, tiff, svg

    var id: Self { self }

    var title: String {
        switch self {
        case .same: "Same as original"
        default: ImageFormat(rawValue: rawValue)!.name
        }
    }
}

enum OutputMode: String, CaseIterable, Identifiable, Sendable {
    case replace, copy

    var id: Self { self }

    var title: String {
        switch self {
        case .replace: "Replace original"
        case .copy: "Save copy"
        }
    }
}

enum ViewMode: String, Sendable {
    case grid, table
}

/// Everything the pipeline needs from the inspector, captured when a batch starts.
struct ProcessingOptions: Sendable, Equatable {
    var resizeEnabled = false
    var resizeMode = ResizeMode.longestEdge
    var resizeValue = 2000
    var formatEnabled = true
    var format = FormatChoice.same
    var quality = 90
    var progressive = true
    var pngMaxEffort = false
    var outputMode = OutputMode.replace
    var prefix = ""
    var suffix = "-small"
    var skipIfLarger = true
}

/// Inspector settings, persisted in UserDefaults (the same storage `@AppStorage` uses).
@MainActor @Observable
final class Settings {
    var resizeEnabled: Bool { didSet { store(resizeEnabled, .resizeEnabled) } }
    var resizeMode: ResizeMode { didSet { store(resizeMode.rawValue, .resizeMode) } }
    var resizeValue: Int { didSet { store(resizeValue, .resizeValue) } }
    var formatEnabled: Bool { didSet { store(formatEnabled, .formatEnabled) } }
    var format: FormatChoice { didSet { store(format.rawValue, .format) } }
    var quality: Int { didSet { store(quality, .quality) } }
    var progressive: Bool { didSet { store(progressive, .progressive) } }
    var pngMaxEffort: Bool { didSet { store(pngMaxEffort, .pngMaxEffort) } }
    var outputMode: OutputMode { didSet { store(outputMode.rawValue, .outputMode) } }
    var prefix: String { didSet { store(prefix, .prefix) } }
    var suffix: String { didSet { store(suffix, .suffix) } }
    var skipIfLarger: Bool { didSet { store(skipIfLarger, .skipIfLarger) } }
    var viewMode: ViewMode { didSet { store(viewMode.rawValue, .viewMode) } }

    private enum Key: String {
        case resizeEnabled, resizeMode, resizeValue, formatEnabled, format, quality, progressive, pngMaxEffort
        case outputMode, prefix, suffix, skipIfLarger, viewMode
    }

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let d = ProcessingOptions()
        func value<T>(_ key: Key, _ fallback: T) -> T { defaults.object(forKey: key.rawValue) as? T ?? fallback }
        resizeEnabled = value(.resizeEnabled, d.resizeEnabled)
        resizeMode = ResizeMode(rawValue: value(.resizeMode, "")) ?? d.resizeMode
        resizeValue = value(.resizeValue, d.resizeValue)
        formatEnabled = value(.formatEnabled, d.formatEnabled)
        format = FormatChoice(rawValue: value(.format, "")) ?? d.format
        quality = value(.quality, d.quality)
        progressive = value(.progressive, d.progressive)
        pngMaxEffort = value(.pngMaxEffort, d.pngMaxEffort)
        outputMode = OutputMode(rawValue: value(.outputMode, "")) ?? d.outputMode
        prefix = value(.prefix, d.prefix)
        suffix = value(.suffix, d.suffix)
        skipIfLarger = value(.skipIfLarger, d.skipIfLarger)
        viewMode = ViewMode(rawValue: value(.viewMode, "")) ?? .grid
    }

    private func store(_ value: Any, _ key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    var options: ProcessingOptions {
        ProcessingOptions(
            resizeEnabled: resizeEnabled, resizeMode: resizeMode, resizeValue: resizeValue,
            formatEnabled: formatEnabled, format: format, quality: quality, progressive: progressive, pngMaxEffort: pngMaxEffort,
            outputMode: outputMode, prefix: prefix, suffix: suffix, skipIfLarger: skipIfLarger)
    }

    /// Characters that can't appear in a file name on macOS (`:` shows as `/` in Finder).
    nonisolated static func invalidAffix(_ text: String) -> Bool {
        text.contains("/") || text.contains(":")
    }

    var affixesValid: Bool { !Self.invalidAffix(prefix) && !Self.invalidAffix(suffix) }
}
