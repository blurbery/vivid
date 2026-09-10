// Compile alongside VividInitialAudioStream.swift. No playback libraries are needed.
@main
struct AudioSelectionRegression {
    static func main() {
        let sparse = [0, 3, 8]
        precondition(VividInitialAudioStream.resolve(explicit: nil, ordinal: 1, streamIndices: sparse) == 3)
        precondition(VividInitialAudioStream.resolve(explicit: 8, ordinal: 1, streamIndices: sparse) == 8)
        precondition(VividInitialAudioStream.resolve(explicit: nil, ordinal: -1, streamIndices: sparse) == nil)
        precondition(VividInitialAudioStream.resolve(explicit: nil, ordinal: 3, streamIndices: sparse) == nil)
        precondition(VividInitialAudioStream.resolve(explicit: nil, ordinal: 0, streamIndices: []) == nil)
        precondition(VividInitialAudioStream.resolve(explicit: nil, ordinal: nil, streamIndices: sparse) == nil)
        precondition(VividInitialAudioStream.resolve(explicit: nil, ordinal: 0, streamIndices: [Int.max]) == nil)
        print("Audio selection regression checks passed (7 cases).")
    }
}
