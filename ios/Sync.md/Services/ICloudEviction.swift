import Foundation

/// iCloud Drive replaces a file it has evicted from the device with a small
/// `.<name>.icloud` placeholder next to where the file was. To Git the
/// original then looks deleted and the placeholder looks new, and as files
/// download and evict the picture keeps changing. Neither is a change the
/// user made, so status, staging, and whole-tree passes all ignore them.
/// The committed copy of an evicted file is left exactly as it is.
nonisolated enum ICloudEviction {
    static func isPlaceholder(path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix(".") && name.hasSuffix(".icloud") && name.count > ".icloud".count + 1
    }

    static func placeholderURL(for path: String, in repositoryURL: URL) -> URL {
        let fileURL = repositoryURL.appendingPathComponent(path)
        let name = fileURL.lastPathComponent
        return fileURL.deletingLastPathComponent().appendingPathComponent(".\(name).icloud")
    }

    /// True when the file itself is absent but iCloud's placeholder for it
    /// exists, meaning the file is evicted rather than deleted.
    static func isEvicted(path: String, in repositoryURL: URL) -> Bool {
        let fileManager = FileManager.default
        let fileURL = repositoryURL.appendingPathComponent(path)
        if fileManager.fileExists(atPath: fileURL.path) { return false }
        return fileManager.fileExists(atPath: placeholderURL(for: path, in: repositoryURL).path)
    }
}
