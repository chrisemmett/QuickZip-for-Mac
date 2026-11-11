import Foundation

extension Bundle {
    /// Where ArchiveKit's String Catalog lives, found without
    /// `Bundle.module`, which traps if the resource bundle is not where
    /// the build left it. A command-line tool run from /usr/local/bin, or
    /// a test host, has it somewhere else (or nowhere), and an error message
    /// must never be the thing that crashes. If no bundle is found, strings
    /// come out in the English written in the source.
    static let archiveKitStrings: Bundle = {
        let name = "ArchiveKit_ArchiveKit.bundle"
        var directories: [URL] = []
        if let resources = Bundle.main.resourceURL { directories.append(resources) }
        directories.append(Bundle.main.bundleURL)
        directories.append(Bundle.main.bundleURL.deletingLastPathComponent())
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            let beside = executable.deletingLastPathComponent()
            directories.append(beside)
            // A tool in App.app/Contents/Helpers uses the app's copy.
            directories.append(beside.deletingLastPathComponent().appendingPathComponent("Resources"))
        }
        for directory in directories {
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) { return bundle }
        }
        return .main
    }()
}
