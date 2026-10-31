import Foundation
import AVFoundation
import MLX
import MLXAudioSTT
import MLXNN

@main struct Probe {
 static func decode(_ model: Qwen3ASRModel, _ embedding: Embedding, _ audio: MLXArray, _ count: Int, _ language: String?) throws -> String {
  guard let tokenizer = model.tokenizer else { fatalError("tokenizer missing") }
  let ids = model.buildPrompt(numAudioTokens:count,context:"",language:language)
  let embeds = embedding(ids)
  let merged = model.mergeAudioFeatures(inputsEmbeds:embeds,audioFeatures:audio.asType(embeds.dtype),inputIds:ids)
  let cache = model.makeCache()
  var logits = model.callAsFunction(inputIds:ids,inputEmbeddings:merged,cache:cache);eval(logits)
  var tokens: [Int] = []
  for _ in 0..<128 {
   try Task.checkCancellation()
   let next = logits[0..., -1, 0...].argMax(axis:-1).item(Int.self)
   if next == 151645 || next == 151643 { break }
   tokens.append(next)
   if tokens.count >= 24 && Set(tokens.suffix(24)).count <= 3 { break }
   logits = model.callAsFunction(inputIds:MLXArray([Int32(next)]).expandedDimensions(axis:0),cache:cache);eval(logits)
  }
  let text = tokenizer.decode(tokens:tokens).trimmingCharacters(in:.whitespacesAndNewlines)
  if language == nil, text.hasPrefix("language "), let marker = text.range(of:"<asr_text>") {
   return String(text[marker.upperBound...]).trimmingCharacters(in:.whitespacesAndNewlines)
  }
  return text
 }
 static func main() async throws {
  let args = CommandLine.arguments
  guard args.count == 3 else { fatalError("model-directory mono16k-wav required") }
  let source = URL(fileURLWithPath: args[1])
  let staging = FileManager.default.temporaryDirectory.appending(path: "msub-probe-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: staging) }
  for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
   try FileManager.default.createSymbolicLink(at: staging.appending(path: file.lastPathComponent), withDestinationURL: file)
  }
  let model = try await Qwen3ASRModel.fromModelDirectory(staging)
  let audio = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
  guard audio.processingFormat.sampleRate == 16000, audio.processingFormat.channelCount == 1, audio.length >= 320000 else { fatalError("mono16k required") }
  var features: [MLXArray] = [], masks: [MLXArray] = [], inputs: [MLXArray] = []
  var tokenCounts: [Int] = []
  for count in [96000, 160000] {
   let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(count))!
   try audio.read(into: buffer, frameCount: AVAudioFrameCount(count))
   guard buffer.frameLength > 0, let data = buffer.floatChannelData else { fatalError("need two nonempty windows") }
   let input = MLXArray(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
   let (f,m,n) = model.preprocessAudio(input);eval(f,m);features.append(f);masks.append(m);inputs.append(input);tokenCounts.append(n)
  }
  let frames = features.map{$0.dim(2)}.max()!
  let batch = concatenated(features.map{padded($0,widths:[IntOrPair((0,0)),IntOrPair((0,0)),IntOrPair((0,frames-$0.dim(2)))])},axis:0)
  let mask = concatenated(masks.map{padded($0,widths:[IntOrPair((0,0)),IntOrPair((0,frames-$0.dim(1)))])},axis:0)
  eval(batch,mask)
  guard let embedding = model.namedModules().first(where: { $0.0 == "model.embed_tokens" })?.1 as? Embedding else { fatalError("embedding module unavailable") }
  let encoded = model.getAudioFeatures(batch, featureAttentionMask:mask);eval(encoded)
  guard encoded.dim(0) == tokenCounts.reduce(0,+) else {fatalError("feature partition mismatch")}
  var rows: [[String:Any]] = []
  for language in [Optional("ja"), nil] {
   for i in 0..<2 {
    var original = ""
    let start = ProcessInfo.processInfo.systemUptime
    for try await event in model.generateStream(audio:inputs[i],maxTokens:128,temperature:0,context:"",language:language,chunkDuration:30,minChunkDuration:0) {
     if case .result(let result) = event { original = result.text }
    }
    let referenceSeconds = ProcessInfo.processInfo.systemUptime-start
    let single = model.getAudioFeatures(features[i],featureAttentionMask:masks[i]);eval(single)
    let singleText = try decode(model, embedding, single, tokenCounts[i], language)
    let offset = tokenCounts.prefix(i).reduce(0,+)
    let startDecode = ProcessInfo.processInfo.systemUptime
    let batchText = try decode(model, embedding, encoded[offset..<(offset+tokenCounts[i])], tokenCounts[i], language)
    rows.append(["index":i,"language":language ?? "auto","singleFeatureTextMatches":singleText == original,
                 "batchFeatureTextMatches":batchText == original,"referenceCharacters":original.count,
                 "referenceSeconds":referenceSeconds,"batchDecodeSeconds":ProcessInfo.processInfo.systemUptime-startDecode])
   }
  }
  let report:[String:Any] = ["windowsSeconds":[6,10],"maxTokens":128,"rows":rows,"note":"Greedy decode against upstream; literal text comparison, not a quality corpus or end-to-end speed benchmark."]
  print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
