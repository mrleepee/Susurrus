import Foundation
import WhisperKit

// Usage: SpikeEval <modelFolder> <outJSON> <prompt|-> <wav>...
// Mirrors StreamingTranscriptionService's final decode options.
let args = CommandLine.arguments
let modelFolder = args[1], outPath = args[2], prompt = args[3]
let wavs = Array(args.dropFirst(4))

let kit = try await WhisperKit(modelFolder: modelFolder, computeOptions: ModelComputeOptions(
    audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine))
var options = DecodingOptions(task: .transcribe, language: "en", concurrentWorkerCount: 4, chunkingStrategy: .vad)
if prompt != "-", let tok = kit.tokenizer {
    options.promptTokens = Array(tok.encode(text: prompt).prefix(48))
}
// Prewarm so the first clip doesn't pay ANE specialisation.
let warm = (0..<16000).map { i in Float(0.1 * sin(2.0 * .pi * 300.0 * Double(i) / 16000.0)) }
_ = try? await kit.transcribe(audioArray: warm, decodeOptions: options)

var rows: [[String: Any]] = []
for path in wavs {
    let samples = AudioProcessor.convertBufferToArray(buffer: try AudioProcessor.loadAudio(fromPath: path))
    let start = Date()
    let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    let segs = results.flatMap(\.segments).map { ["text": $0.text, "avgLogprob": $0.avgLogprob, "noSpeechProb": $0.noSpeechProb, "start": $0.start, "end": $0.end] as [String: Any] }
    rows.append(["id": URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
                 "text": text, "ms": ms, "seconds": Double(samples.count) / 16000, "segments": segs])
    FileHandle.standardError.write("\(path): \(ms)ms\n".data(using: .utf8)!)
}
try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted]).write(to: URL(fileURLWithPath: outPath))
