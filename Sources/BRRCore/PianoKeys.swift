import Foundation

/// Maps computer keys to piano keys, laid out as in most DAWs: Q–P for the white keys,
/// with 2 3 5 6 7 for the black keys above them.
public enum PianoKeys {
    /// Semitone offset from the C at the start of the octave.
    private static let semitones: [Character: Int] = [
        "q": 0, "2": 1, "w": 2, "3": 3, "e": 4, "r": 5, "5": 6, "t": 7,
        "6": 8, "y": 9, "7": 10, "u": 11, "i": 12, "9": 13, "o": 14, "0": 15, "p": 16,
    ]

    /// MIDI note for `key` within the octave whose C is `octaveBase`, or nil if `key` isn't a piano key.
    public static func midi(for key: Character, octaveBase: Int) -> Int? {
        guard key.isASCII, let offset = semitones[Character(key.lowercased())] else { return nil }
        return octaveBase + offset
    }
}
