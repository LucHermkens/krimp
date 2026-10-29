import Foundation

enum WriteError: LocalizedError {
    case readOnly
    case notReplaced
    case invalidName

    var errorDescription: String? {
        switch self {
        case .readOnly: "File is read-only"
        case .notReplaced: "Not replaced (no Trash on this volume)"
        case .invalidName: "Prefix and suffix can't contain / or :"
        }
    }
}

enum Writer {
    /// Extension for the output: the original's (same spelling/case) when the format is unchanged.
    static func outputExtension(for source: URL, format: ImageFormat) -> String {
        let ext = source.pathExtension
        return format.knownExtensions.contains(ext.lowercased()) ? ext : format.fileExtension
    }

    /// `<prefix><basename><suffix>.<ext>`. With an empty prefix and suffix the name would equal the
    /// original's when the extension is unchanged, so `-copy` is used instead.
    static func copyName(for source: URL, ext: String, prefix: String, suffix: String) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        var suffix = suffix
        if prefix.isEmpty && suffix.isEmpty && ext.lowercased() == source.pathExtension.lowercased() {
            suffix = "-copy"
        }
        return "\(prefix)\(base)\(suffix).\(ext)"
    }

    /// `url` if nothing exists there, otherwise `name-2.ext`, `name-3.ext`, …
    static func availableURL(_ url: URL, fileManager: FileManager = .default) -> URL {
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = dir.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    /// Writes next to the original without ever overwriting anything.
    static func saveCopy(_ data: Data, source: URL, format: ImageFormat, prefix: String, suffix: String,
                         fileManager: FileManager = .default) throws -> URL {
        guard !Settings.invalidAffix(prefix), !Settings.invalidAffix(suffix) else { throw WriteError.invalidName }
        let ext = outputExtension(for: source, format: format)
        let name = copyName(for: source, ext: ext, prefix: prefix, suffix: suffix)
        while true {
            let target = availableURL(source.deletingLastPathComponent().appendingPathComponent(name), fileManager: fileManager)
            do {
                try data.write(to: target, options: .withoutOverwriting)
                return target
            } catch CocoaError.fileWriteFileExists {
                continue  // lost a race with another writer; pick the next free name
            } catch {
                try? fileManager.removeItem(at: target)
                throw error
            }
        }
    }

    /// Writes to a temp file on the same volume, moves the original to the Trash, then moves the
    /// temp file to `<basename>.<ext>`. If the volume has no Trash, `confirmPermanent` decides
    /// whether to delete the original instead; nothing is ever deleted silently.
    static func replace(_ data: Data, source: URL, format: ImageFormat,
                        confirmPermanent: @Sendable (URL) async -> Bool,
                        fileManager: FileManager = .default) async throws -> URL {
        guard fileManager.isWritableFile(atPath: source.path) else { throw WriteError.readOnly }

        let ext = outputExtension(for: source, format: format)
        var target = source.deletingPathExtension().appendingPathExtension(ext)
        if target.standardizedFileURL != source.standardizedFileURL {
            target = availableURL(target, fileManager: fileManager)
        }

        let tempDir = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                          appropriateFor: source, create: true)
        defer { try? fileManager.removeItem(at: tempDir) }
        let temp = tempDir.appendingPathComponent(target.lastPathComponent)
        try data.write(to: temp)

        var trashed: NSURL?
        do {
            try fileManager.trashItem(at: source, resultingItemURL: &trashed)
        } catch let error as CocoaError where error.code == .featureUnsupported {
            guard await confirmPermanent(source) else { throw WriteError.notReplaced }
            try fileManager.removeItem(at: source)
        }

        do {
            try fileManager.moveItem(at: temp, to: target)
        } catch {
            // Put the original back where it was.
            if let trashed = trashed as URL?, !fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: trashed, to: source)
            }
            throw error
        }
        return target
    }
}
