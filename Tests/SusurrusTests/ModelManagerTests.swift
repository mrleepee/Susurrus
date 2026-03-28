import Testing
@testable import SusurrusKit

/// Thread-safe collector for progress values in @Sendable closures.
final class ProgressCollector: @unchecked Sendable {
    private var _values: [Double] = []
    func add(_ value: Double) { _values.append(value) }
    var values: [Double] { _values }
}

/// Mock model manager for testing without network.
actor MockModelManager: ModelManaging {
    var cachedModels: Set<String> = []
    var downloadCallCount = 0
    var lastDownloadedModel: String?
    var shouldFailDownload = false
    nonisolated(unsafe) var mockCachePath: String = "/tmp/susurrus-test"

    func isModelCached(modelName: String) async -> Bool {
        cachedModels.contains(modelName)
    }

    func downloadModel(
        modelName: String,
        onProgress: (@Sendable (Double) -> Void)?
    ) async throws {
        downloadCallCount += 1
        lastDownloadedModel = modelName

        if shouldFailDownload {
            throw ModelManagerError.downloadFailed("mock failure")
        }

        onProgress?(0.5)
        onProgress?(1.0)
        cachedModels.insert(modelName)
    }

    nonisolated func modelCachePath() -> String {
        mockCachePath
    }

    func setCached(_ models: Set<String>) {
        cachedModels = models
    }

    func setFailure() {
        shouldFailDownload = true
    }
}

@Suite("ModelManager Tests")
struct ModelManagerTests {

    @Test("Model is not cached by default")
    func notCachedByDefault() async {
        let manager = MockModelManager()
        let cached = await manager.isModelCached(modelName: "large-v3")
        #expect(cached == false)
    }

    @Test("Download marks model as cached")
    func downloadMarksCached() async throws {
        let manager = MockModelManager()
        try await manager.downloadModel(modelName: "large-v3", onProgress: nil)
        let cached = await manager.isModelCached(modelName: "large-v3")
        #expect(cached == true)
    }

    @Test("Download calls progress callback")
    func downloadProgress() async throws {
        let manager = MockModelManager()
        let progressCollector = ProgressCollector()

        try await manager.downloadModel(modelName: "large-v3") { progress in
            progressCollector.add(progress)
        }

        let values = progressCollector.values
        #expect(values.count == 2)
        #expect(values[0] == 0.5)
        #expect(values[1] == 1.0)
    }

    @Test("Download failure throws error")
    func downloadFailure() async {
        let manager = MockModelManager()
        await manager.setFailure()

        do {
            try await manager.downloadModel(modelName: "large-v3", onProgress: nil)
            #expect(Bool(false), "Should have thrown")
        } catch let error as ModelManagerError {
            #expect(error == .downloadFailed("mock failure"))
        } catch {
            #expect(Bool(false), "Unexpected error: \(error)")
        }
    }

    @Test("Model not re-downloaded when cached")
    func skipDownloadWhenCached() async throws {
        let manager = MockModelManager()
        await manager.setCached(["large-v3"])

        let cached = await manager.isModelCached(modelName: "large-v3")
        #expect(cached == true)

        // Should not call download since model is cached
        let count = await manager.downloadCallCount
        #expect(count == 0)
    }

    @Test("Cache path returns a string")
    func cachePath() async {
        let manager = MockModelManager()
        let path = await manager.modelCachePath()
        #expect(path.contains("susurrus-test"))
    }

    @Test("ModelManagerError equality")
    func errorEquality() {
        #expect(ModelManagerError.downloadFailed("a") == ModelManagerError.downloadFailed("a"))
        #expect(ModelManagerError.downloadFailed("a") != ModelManagerError.downloadFailed("b"))
        #expect(ModelManagerError.cacheDirectoryUnavailable == ModelManagerError.cacheDirectoryUnavailable)
    }

    @Test("Download tracks call count and model name")
    func downloadTracking() async throws {
        let manager = MockModelManager()
        try await manager.downloadModel(modelName: "base", onProgress: nil)

        let count = await manager.downloadCallCount
        #expect(count == 1)

        let lastModel = await manager.lastDownloadedModel
        #expect(lastModel == "base")
    }
}
