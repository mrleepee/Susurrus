import Foundation

/// Protocol for managing WhisperKit model download and caching.
public protocol ModelManaging: Sendable {
    /// Check whether a model is already cached locally.
    func isModelCached(modelName: String) async -> Bool

    /// Download and cache the specified model. Throws on network failure.
    /// `onProgress` is called periodically with a Double in 0...1.
    func downloadModel(modelName: String, onProgress: (@Sendable (Double) -> Void)?) async throws

    /// Return the local path where models are cached.
    func modelCachePath() -> String
}

/// Errors during model management.
public enum ModelManagerError: Error, Sendable, Equatable {
    case downloadFailed(String)
    case modelNotFound(String)
    case cacheDirectoryUnavailable
}
