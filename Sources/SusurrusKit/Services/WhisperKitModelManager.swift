import Foundation
import WhisperKit

/// Concrete model manager using WhisperKit's download and caching.
/// Stores models in ~/Library/Application Support/Susurrus/.
public actor WhisperKitModelManager: ModelManaging {

    private let fileManager = FileManager.default

    /// The base directory for model caching.
    private let cacheBaseName: String

    public init(cacheBaseName: String = "Susurrus") {
        self.cacheBaseName = cacheBaseName
    }

    public nonisolated func modelCachePath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent(cacheBaseName).path
    }

    public func isModelCached(modelName: String) async -> Bool {
        let modelDirPath = modelCachePath()
        let modelDir = URL(fileURLWithPath: modelDirPath)
        let contents = try? fileManager.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )
        return contents?.contains { url in
            url.lastPathComponent.contains(modelName)
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        } ?? false
    }

    public func downloadModel(
        modelName: String,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let cacheDirPath = modelCachePath()
        let cacheDir = URL(fileURLWithPath: cacheDirPath)

        // Ensure cache directory exists
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }

        do {
            _ = try await WhisperKit.download(
                variant: modelName,
                downloadBase: cacheDir,
                progressCallback: { progress in
                    guard progress.totalUnitCount > 0 else { return }
                    let fraction = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
                    onProgress?(fraction)
                }
            )
        } catch {
            throw ModelManagerError.downloadFailed(error.localizedDescription)
        }
    }
}
