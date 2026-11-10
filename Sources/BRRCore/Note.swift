import Foundation

/// Equal-temperament helpers using MIDI note numbers (C4 = 60, A4 = 440 Hz).
public enum Note {
    public static let referenceMIDI = 60

    private static let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]

    public static func frequency(midi: Double) -> Double {
        440 * pow(2, (midi - 69) / 12)
    }

    public static func midi(frequency: Double) -> Double {
        69 + 12 * log2(frequency / 440)
    }

    public static func name(midi: Int) -> String {
        let octave = midi / 12 - 1
        return names[((midi % 12) + 12) % 12] + String(octave)
    }

    private static let semitones: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// Reads a note such as "C5", "F#3", or "Bb2" at the end of `text`, preceded by a space or the start.
    public static func midi(parsing text: String) -> Int? {
        guard let match = text.firstMatch(of: #/(?:^|\s)([A-G])([#b]?)(-?\d+)$/#) else { return nil }
        let letter = Character(String(match.1))
        guard let semitone = semitones[letter], let octave = Int(match.3) else { return nil }
        let accidental = match.2 == "#" ? 1 : match.2 == "b" ? -1 : 0
        let midi = (octave + 1) * 12 + semitone + accidental
        return (0...127).contains(midi) ? midi : nil
    }
}
