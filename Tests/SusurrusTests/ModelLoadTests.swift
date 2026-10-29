import Testing
@testable import SusurrusKit
import WhisperKit

@Suite("Model Load Tests")
struct ModelLoadTests {

    @Test("Download and load small model")
    func loadSmallModel() async throws {
        let service = WhisperKitTranscriptionService()

        try await service.setupModel(modelName: "small") { progress in
            print("Progress: \(progress)")
        }

        let ready = await service.isModelReady()
        print("Model ready: \(ready)")
        #expect(ready == true)
    }
}
