import Foundation

/// Mono source audio that can be edited before it is encoded to BRR.
/// Edits run at the source rate, and resampling happens only at encode time.
public struct EditableSample: Equatable {
    /// Mono samples in -1...1.
    public var samples: [Float]
    public var sourceRate: Double
    /// Index into `samples` where the loop begins, or nil for no loop.
    public var loopStart: Int?

    public init(samples: [Float], sourceRate: Double, loopStart: Int? = nil) {
        self.samples = samples
        self.sourceRate = sourceRate
        self.loopStart = loopStart
    }

    public var duration: Double { Double(samples.count) / sourceRate }

    /// Keeps only `range`. A loop inside the range moves with it, a loop before the range becomes the start,
    /// and a loop after the range is removed.
    public mutating func crop(_ range: Range<Int>) {
        guard let r = clamped(range) else { return }
        if let loop = loopStart {
            if loop < r.lowerBound {
                loopStart = 0
            } else if loop < r.upperBound {
                loopStart = loop - r.lowerBound
            } else {
                loopStart = nil
            }
        }
        samples = Array(samples[r])
    }

    /// Removes `range`. A loop after the cut shifts back, and a loop inside the cut moves to the cut point.
    public mutating func cut(_ range: Range<Int>) {
        guard let r = clamped(range) else { return }
        if let loop = loopStart {
            if loop >= r.upperBound {
                loopStart = loop - r.count
            } else if loop >= r.lowerBound {
                loopStart = r.lowerBound
            }
        }
        samples.removeSubrange(r)
    }

    /// Reverses `range`. A loop inside the range is removed, because its position no longer means anything.
    public mutating func reverse(_ range: Range<Int>) {
        guard let r = clamped(range) else { return }
        if let loop = loopStart, r.contains(loop) {
            loopStart = nil
        }
        samples[r].reverse()
    }

    public mutating func fadeIn(_ range: Range<Int>) {
        guard let r = clamped(range) else { return }
        for (offset, i) in r.enumerated() {
            samples[i] *= Float(offset + 1) / Float(r.count)
        }
    }

    public mutating func fadeOut(_ range: Range<Int>) {
        guard let r = clamped(range) else { return }
        for (offset, i) in r.enumerated() {
            samples[i] *= Float(r.count - offset) / Float(r.count)
        }
    }

    /// Scales the whole sample so its peak is 0.99.
    public mutating func normalize() {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0 else { return }
        let gain = 0.99 / peak
        samples = samples.map { $0 * gain }
    }

    /// Removes leading and trailing samples whose magnitude stays below `threshold`.
    public mutating func trimSilence(threshold: Float = 0.002) {
        guard let first = samples.firstIndex(where: { abs($0) >= threshold }),
              let last = samples.lastIndex(where: { abs($0) >= threshold }) else { return }
        crop(first..<(last + 1))
    }

    private func clamped(_ range: Range<Int>) -> Range<Int>? {
        let lower = max(0, range.lowerBound)
        let upper = min(samples.count, range.upperBound)
        return lower < upper ? lower..<upper : nil
    }
}
