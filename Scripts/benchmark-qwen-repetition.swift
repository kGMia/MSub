import Foundation
import MLX
struct SubtitleSegment: Sendable { let index:Int; let start:Double; let end:Double; let duration:Double }
struct SubtitleCue: Sendable { let index:Int; let start:Double; let end:Double; let text:String; let confidence:Double?; let speaker:String? }
@main struct Probe {
 static func main() async throws {
    let original = MLXArray([Float(4), -4, 2, -2], [1,4])
    let adjusted = NativeQwenService.penalizedLogits(original, tokens:[0,0,1], penalty:2, contextSize:100)
    precondition(adjusted.asArray(Float.self) == [2,-8,2,-2])
    precondition(original.asArray(Float.self) == [4,-4,2,-2])
    let limited = NativeQwenService.penalizedLogits(original, tokens:[0,1], penalty:2, contextSize:1)
    precondition(limited.asArray(Float.self) == [4,-8,2,-2])
    var rows: [[String:Any]] = []
    var protectedTexts: [String]?
    let segments = [SubtitleSegment(index:1,start:0,end:6,duration:6),SubtitleSegment(index:2,start:6,end:16,duration:10),SubtitleSegment(index:3,start:16,end:21,duration:5)]
    for (penalty, recovery, optimized) in [(Float(1),false,true),(Float(1),false,true),(Float(1),true,true),(Float(1.05),false,true),(Float(1.05),true,true),(Float(1.05),true,false)] {
        let started = ProcessInfo.processInfo.systemUptime
        let cues = try await NativeQwenService.shared.transcribe(audioURL:URL(fileURLWithPath:CommandLine.arguments[2]),segments:segments,timeOffset:12,
            options:.init(modelDirectory:URL(fileURLWithPath:CommandLine.arguments[1]),language:"ja",context:"",maxTokens:128,lineCharacters:30,
                          optimizedDecodingEnabled:optimized,repetitionPenalty:penalty,repetitionRecoveryEnabled:recovery),checkpoint:{},onProgress:{_ in})
        precondition(cues.map(\.start) == [12,18,28] && cues.map(\.end) == [18,28,33])
        rows.append(["penalty":penalty,"recovery":recovery,"optimized":optimized,"seconds":ProcessInfo.processInfo.systemUptime-started,
                     "characters":cues.map{$0.text.count},"loopFlags":cues.map{NativeQwenRepetition.hasPhraseLoop($0.text)}])
        if penalty > 1 && recovery {
            if let protectedTexts { precondition(protectedTexts == cues.map(\.text), "stream/optimized parity") }
            else { protectedTexts = cues.map(\.text) }
        }
        if recovery { precondition(!cues.contains { NativeQwenRepetition.hasPhraseLoop($0.text) }) }
    }
    await NativeQwenService.shared.release()
    print(String(decoding:try JSONSerialization.data(withJSONObject:["runs":rows,"signAwarePenaltyAndContext":true],options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
 }
}
