import Foundation
import AVFoundation
import MLX
import MLXAudioSTT

@main struct Probe {
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
  var features: [MLXArray] = [], masks: [MLXArray] = []
  for _ in 0..<2 {
   let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 160000)!
   try audio.read(into: buffer, frameCount: 160000)
   guard buffer.frameLength > 0, let data = buffer.floatChannelData else { fatalError("need two nonempty windows") }
   let input = MLXArray(Array(UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))))
   let (f,m,_) = model.preprocessAudio(input);eval(f,m);features.append(f);masks.append(m)
  }
  let frames = features.map{$0.dim(2)}.max()!
  let batch = concatenated(features.map{padded($0,widths:[IntOrPair((0,0)),IntOrPair((0,0)),IntOrPair((0,frames-$0.dim(2)))])},axis:0)
  let mask = concatenated(masks.map{padded($0,widths:[IntOrPair((0,0)),IntOrPair((0,frames-$0.dim(1)))])},axis:0)
  eval(batch,mask)
  var results: [[String:Any]] = []
  for round in 0..<3 {
   var reference: [MLXArray] = []
   let t = ProcessInfo.processInfo.systemUptime
   for i in 0..<2 {let x=model.getAudioFeatures(features[i],featureAttentionMask:masks[i]);eval(x);reference.append(x)}
   let sequential=ProcessInfo.processInfo.systemUptime-t
   let start=ProcessInfo.processInfo.systemUptime
   let actual=model.getAudioFeatures(batch,featureAttentionMask:mask);eval(actual)
   let batchSeconds=ProcessInfo.processInfo.systemUptime-start
   let expected=concatenated(reference,axis:0)
   guard expected.shape == actual.shape else {fatalError("shape mismatch")}
   let error=MLX.max(MLX.abs(actual.asType(.float32)-expected.asType(.float32))).item(Float.self)
   results.append(["round":round,"sequentialSeconds":sequential,"batchSeconds":batchSeconds,"maxFeatureError":error,"processPeakBytes":Memory.peakMemory,"shape":actual.shape])
  }
  let report:[String:Any] = ["windows":2,"secondsPerWindow":10,"rounds":results,"note":"Encoder only; no transcript/decoder parity claim. Same-process, sequential-first order."]
  print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
 }
}
