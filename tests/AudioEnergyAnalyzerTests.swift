import Foundation

@main
struct AudioEnergyAnalyzerTests {
    static func analyze(
        _ samples: [Float],
        right suppliedRight: [Float]? = nil,
        chunks: [Int],
        sampleRate: Double = 48_000
    ) -> [AudioFrame] {
        precondition(suppliedRight == nil || suppliedRight!.count == samples.count)
        var left = samples
        var right = suppliedRight ?? samples
        let channelCount = suppliedRight == nil ? 1 : 2
        var frames: [AudioFrame] = []
        let analyzer = AudioEnergyAnalyzer()
        left.withUnsafeMutableBufferPointer { leftBuffer in
            right.withUnsafeMutableBufferPointer { rightBuffer in
                var offset = 0
                var chunk = 0
                while offset < samples.count {
                    let count = min(chunks[chunk % chunks.count], samples.count - offset)
                    let pointers = [
                        leftBuffer.baseAddress!.advanced(by: offset),
                        rightBuffer.baseAddress!.advanced(by: offset)
                    ]
                    pointers.withUnsafeBufferPointer { channels in
                        analyzer.process(
                            channels: channels.baseAddress!,
                            channelCount: channelCount,
                            frameCount: count,
                            sampleRate: sampleRate,
                            endingAt: 1000 + Double(offset + count) / sampleRate,
                            emit: { frames.append($0) }
                        )
                    }
                    offset += count
                    chunk += 1
                }
            }
        }
        return frames
    }

    static func bandsMatch(_ first: [Double], _ second: [Double], tolerance: Double) -> Bool {
        first.count == second.count
            && zip(first, second).allSatisfy { abs($0 - $1) <= tolerance }
    }

    static func strongestBand(in bands: [Double]) -> Int {
        bands.indices.max { bands[$0] < bands[$1] }!
    }

    static func logarithmicBand(for frequency: Double) -> Int {
        let position = log(frequency / AudioEngineProtocol.minimumFrequency)
            / log(
                AudioEngineProtocol.maximumFrequency
                    / AudioEngineProtocol.minimumFrequency
            )
        return min(
            AudioEngineProtocol.bandCount - 1,
            max(0, Int(floor(position * Double(AudioEngineProtocol.bandCount))))
        )
    }

    static func main() {
        let samples = (0..<48_000).map { index in
            Float(sin(Double(index) * 2 * .pi * 220 / 48_000) * (index < 24_000 ? 0.08 : 0.6))
        }
        let whole = analyze(samples, chunks: [samples.count])
        let fragmented = analyze(samples, chunks: [127, 509, 1024, 73])
        precondition(
            whole.count == 50 && fragmented.count == whole.count,
            "audio windows must not be skipped between callbacks"
        )
        for (first, second) in zip(whole, fragmented) {
            precondition(
                abs(first.timestamp - second.timestamp) < 1e-9,
                "callback size changed the sample timeline"
            )
            for channel in 0..<2 {
                precondition(
                    abs(first.channels[channel].level - second.channels[channel].level) < 1e-12,
                    "callback size changed channel energy"
                )
                precondition(
                    abs(first.channels[channel].peak - second.channels[channel].peak) < 1e-12,
                    "callback size changed channel peak"
                )
                precondition(
                    bandsMatch(
                        first.channels[channel].bands,
                        second.channels[channel].bands,
                        tolerance: 1e-12
                    ),
                    "callback size changed channel spectrum"
                )
            }
            precondition(
                first.channels[0].level == first.channels[1].level
                    && first.channels[0].peak == first.channels[1].peak
                    && bandsMatch(
                        first.channels[0].bands,
                        first.channels[1].bands,
                        tolerance: 0
                    ),
                "mono input was not duplicated exactly"
            )
        }
        let at44100 = analyze(
            Array(repeating: 0.1, count: 44_100),
            chunks: [256, 1024],
            sampleRate: 44_100
        )
        precondition(at44100.count == 50, "window duration depends on sample rate")
        print("PASS independent channels and continuous 20ms windows across callback sizes")

        var transient = Array(repeating: Float(0), count: 960 * 5)
        for index in 1100..<1150 { transient[index] = 0.7 }
        let attack = analyze(transient, chunks: [240])
        precondition(
            attack[1].channels[0].level > 0
                && attack[1].channels[0].peak > attack[1].channels[0].level,
            "short attack was dropped or flattened"
        )
        precondition(
            attack.enumerated().filter { $0.offset != 1 }.allSatisfy {
                $0.element.channels[0].level == 0
            },
            "20ms levels contain invented decay"
        )
        precondition(
            attack.dropFirst(3).allSatisfy {
                $0.channels[0].bands.allSatisfy { $0 == 0 }
            },
            "spectrum did not clear after the finite FFT window"
        )
        print("PASS short attacks retained; finite FFT history clears into silence")

        let strengths: [Float] = [0, 0.001, 0.015, 0.05, 0.15, 0.4, 0.8]
        let levels = strengths.map { amplitude in
            analyze(Array(repeating: amplitude, count: 960), chunks: [960])[0]
                .channels[0].level
        }
        precondition(levels[0] == 0 && levels[1] == 0, "noise floor is not silent")
        for index in 2..<levels.count {
            precondition(levels[index] > levels[index - 1])
        }
        precondition(levels.last! < 1, "ordinary strong audio saturates all bars")
        let opposite = analyze(samples, right: samples.map { -$0 }, chunks: [512])
        precondition(
            zip(whole, opposite).allSatisfy {
                abs($0.channels[0].level - $1.channels[0].level) < 1e-12
                    && abs($1.channels[0].level - $1.channels[1].level) < 1e-12
                    && bandsMatch(
                        $1.channels[0].bands,
                        $1.channels[1].bands,
                        tolerance: 1e-7
                    )
            },
            "stereo phase cancellation must not erase either channel"
        )
        print("PASS loud/quiet contrast without early clipping or stereo cancellation")

        let fftBinWidth = 48_000.0 / 2_048.0
        let leftFrequency = fftBinWidth * 10
        let rightFrequency = fftBinWidth * 128
        let toneFrameCount = 960 * 8
        let leftTone = (0..<toneFrameCount).map { index in
            Float(sin(2 * .pi * leftFrequency * Double(index) / 48_000) * 0.5)
        }
        let rightTone = (0..<toneFrameCount).map { index in
            Float(sin(2 * .pi * rightFrequency * Double(index) / 48_000) * 0.5)
        }
        let stereoTones = analyze(
            leftTone,
            right: rightTone,
            chunks: [111, 997, 64, 1500]
        )
        let steady = stereoTones.last!
        let expectedLeftBand = logarithmicBand(for: leftFrequency)
        let expectedRightBand = logarithmicBand(for: rightFrequency)
        precondition(
            strongestBand(in: steady.channels[0].bands) == expectedLeftBand
                && strongestBand(in: steady.channels[1].bands) == expectedRightBand,
            "left and right tones did not peak in their corresponding logarithmic bands"
        )
        precondition(
            steady.channels[0].bands[expectedLeftBand]
                > steady.channels[0].bands[expectedRightBand]
                && steady.channels[1].bands[expectedRightBand]
                    > steady.channels[1].bands[expectedLeftBand],
            "channel spectra do not preserve their distinct frequencies"
        )
        for frame in stereoTones.dropFirst(3) {
            precondition(
                bandsMatch(
                    frame.channels[0].bands,
                    steady.channels[0].bands,
                    tolerance: 1e-6
                )
                    && bandsMatch(
                        frame.channels[1].bands,
                        steady.channels[1].bands,
                        tolerance: 1e-6
                    ),
                "steady tones produced moving spectra"
            )
        }

        let panned = analyze(
            leftTone,
            right: Array(repeating: 0, count: toneFrameCount),
            chunks: [333, 2048, 17]
        )
        precondition(
            panned.allSatisfy {
                $0.channels[1].level == 0
                    && $0.channels[1].peak == 0
                    && $0.channels[1].bands.allSatisfy { $0 == 0 }
            },
            "left audio leaked into the silent right channel"
        )
        print("PASS independent, steady left/right logarithmic spectra without leakage")
    }
}
