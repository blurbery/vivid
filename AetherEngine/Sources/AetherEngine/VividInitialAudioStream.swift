/// Vivid integration: audio-list ordinals are not container stream indices.
enum VividInitialAudioStream {
    static func resolve(explicit: Int32?, ordinal: Int?, streamIndices: [Int]) -> Int32? {
        if let explicit { return explicit }
        guard let ordinal, streamIndices.indices.contains(ordinal) else { return nil }
        return Int32(exactly: streamIndices[ordinal])
    }
}
