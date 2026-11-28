import Foundation

/// Shared switch for every writer to `~/susurrus_debug.log`.
public enum DebugLog {
    /// True inside `swift test`: tests ran the real services and wrote
    /// dozens of start/stop lines with one timestamp into the user's log
    /// (11-18, 11-20), which read like a second app instance.
    public static let isTestProcess: Bool = {
        let name = ProcessInfo.processInfo.processName
        let env = ProcessInfo.processInfo.environment
        return name == "xctest" || name == "swiftpm-testing-helper" || name.hasSuffix("PackageTests")
            || env["XCTestConfigurationFilePath"] != nil || env["XCTestSessionIdentifier"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
