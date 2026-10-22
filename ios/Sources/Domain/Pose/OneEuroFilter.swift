import Foundation

/// One Euro filter, the smoothing used before any derivative.
///
/// A fixed low pass filter trades jitter against lag: enough smoothing to kill wrist jitter would
/// add a visible delay to fast movement. One Euro adapts its cutoff to speed, so still joints are
/// smoothed hard and fast joints are tracked closely, which is exactly the trade this pipeline
/// needs because velocity is the input to the attempt window and fall detection.
struct OneEuroFilter {
    private let minCutoff: Double
    private let beta: Double
    private let derivativeCutoff: Double

    private var previousValue: Double?
    private var previousDerivative: Double = 0

    init(minCutoff: Double = 1.0, beta: Double = 0.007, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func filter(_ value: Double, dt: Double) -> Double {
        guard dt > 0 else { return value }

        let derivative: Double
        if let previous = previousValue {
            derivative = (value - previous) / dt
        } else {
            derivative = 0
        }

        let filteredDerivative = lowPass(
            derivative,
            alpha: Self.alpha(cutoff: derivativeCutoff, dt: dt),
            previous: previousDerivative
        )
        previousDerivative = filteredDerivative

        let cutoff = minCutoff + beta * abs(filteredDerivative)
        let filtered = lowPass(
            value,
            alpha: Self.alpha(cutoff: cutoff, dt: dt),
            previous: previousValue ?? value
        )
        previousValue = filtered
        return filtered
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        guard cutoff > 0, dt > 0 else { return 1 }
        let tau = 1.0 / (2 * Double.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }

    private func lowPass(_ value: Double, alpha: Double, previous: Double) -> Double {
        alpha * value + (1 - alpha) * previous
    }
}

/// Small numeric helpers shared by the metrics. Kept internal so the public surface stays small.
enum SeriesMath {
    static func median(_ values: [Double]) -> Double? {
        percentile(values, 0.5)
    }

    static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        guard sorted.count > 1 else { return sorted[0] }

        let position = min(max(fraction, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let weight = position - Double(lower)
        return sorted[lower] * (1 - weight) + sorted[upper] * weight
    }

    static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Moving average over a window measured in milliseconds, on a uniformly sampled series.
    static func movingAverage(_ values: [Double], windowMs: Int, samplingHz: Double) -> [Double] {
        let radius = max(1, Int((Double(windowMs) / 1000 * samplingHz).rounded()))
        guard values.count > 1, radius > 0 else { return values }

        var result = [Double](repeating: 0, count: values.count)
        var prefix = [Double](repeating: 0, count: values.count + 1)
        for index in values.indices {
            prefix[index + 1] = prefix[index] + values[index]
        }
        for index in values.indices {
            let low = max(0, index - radius)
            let high = min(values.count - 1, index + radius)
            let sum = prefix[high + 1] - prefix[low]
            result[index] = sum / Double(high - low + 1)
        }
        return result
    }

    /// First derivative on a uniform grid, central differences inside and one sided at the ends.
    static func derivative(_ values: [Double], samplingHz: Double) -> [Double] {
        guard values.count > 1, samplingHz > 0 else {
            return [Double](repeating: 0, count: values.count)
        }
        let dt = 1.0 / samplingHz
        var result = [Double](repeating: 0, count: values.count)
        for index in values.indices {
            if index == 0 {
                result[index] = (values[1] - values[0]) / dt
            } else if index == values.count - 1 {
                result[index] = (values[index] - values[index - 1]) / dt
            } else {
                result[index] = (values[index + 1] - values[index - 1]) / (2 * dt)
            }
        }
        return result
    }
}
