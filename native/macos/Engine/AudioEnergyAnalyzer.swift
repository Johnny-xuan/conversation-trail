import Accelerate
import Foundation

// Audio-queue confined. Accumulates every sample into fixed-duration level
// windows while a longer rolling FFT remains independent of callback sizes.
final class AudioEnergyAnalyzer {
    private static let fftLength = 2_048
    private static let fftBinCount = fftLength / 2 + 1
    private static let fftLog2Length = vDSP_Length(11)
    private static let noiseFloor = 0.0025
    private static let normalization = log1p((1 - noiseFloor) * 20)

    private let fftSetup: FFTSetup
    private var hannWindow = Array(repeating: Float.zero, count: fftLength)
    // Mirroring each write into the second half keeps the newest FFT window
    // contiguous across the ring boundary without per-frame copies.
    private var leftRing = Array(repeating: Float.zero, count: fftLength * 2)
    private var rightRing = Array(repeating: Float.zero, count: fftLength * 2)
    private var fftInput = Array(repeating: Float.zero, count: fftLength)
    private var fftReal = Array(repeating: Float.zero, count: fftLength / 2)
    private var fftImaginary = Array(repeating: Float.zero, count: fftLength / 2)
    private var fftPower = Array(repeating: Float.zero, count: fftBinCount)
    private var bandWeights = Array(
        repeating: Float.zero,
        count: AudioEngineProtocol.bandCount * fftBinCount
    )
    private var bandFirstBins = Array(repeating: 0, count: AudioEngineProtocol.bandCount)
    private var bandBinCounts = Array(repeating: 0, count: AudioEngineProtocol.bandCount)

    private var configuredSampleRate = 0.0
    private var configuredChannelCount = 0
    private var windowFrames = 0
    private var filledWindowFrames = 0
    private var ringWriteIndex = 0
    private var leftSquares = 0.0
    private var rightSquares = 0.0
    private var leftPeak = 0.0
    private var rightPeak = 0.0
    private var sequence: UInt64 = 0

    init() {
        guard let setup = vDSP_create_fftsetup(Self.fftLog2Length, FFTRadix(kFFTRadix2)) else {
            fatalError("Unable to create 2048-point FFT setup")
        }
        fftSetup = setup
        vDSP_hann_window(
            &hannWindow,
            vDSP_Length(Self.fftLength),
            Int32(vDSP_HANN_NORM)
        )
    }

    deinit {
        vDSP_destroy_fftsetup(fftSetup)
    }

    func reset() {
        clearSignalState()
    }

    private func clearSignalState() {
        leftRing.withUnsafeMutableBufferPointer { buffer in
            vDSP_vclr(buffer.baseAddress!, 1, vDSP_Length(buffer.count))
        }
        rightRing.withUnsafeMutableBufferPointer { buffer in
            vDSP_vclr(buffer.baseAddress!, 1, vDSP_Length(buffer.count))
        }
        filledWindowFrames = 0
        ringWriteIndex = 0
        leftSquares = 0
        rightSquares = 0
        leftPeak = 0
        rightPeak = 0
    }

    private func configure(sampleRate: Double, channelCount: Int) {
        clearSignalState()
        configuredSampleRate = sampleRate
        configuredChannelCount = channelCount
        windowFrames = max(
            1,
            Int((sampleRate / Double(AudioEngineProtocol.framesPerSecond)).rounded())
        )
        configureBandWeights()
    }

    private func configureBandWeights() {
        bandWeights.withUnsafeMutableBufferPointer { buffer in
            vDSP_vclr(buffer.baseAddress!, 1, vDSP_Length(buffer.count))
        }

        let binWidth = configuredSampleRate / Double(Self.fftLength)
        let nyquist = configuredSampleRate / 2
        let frequencyRatio =
            AudioEngineProtocol.maximumFrequency / AudioEngineProtocol.minimumFrequency

        for band in 0..<AudioEngineProtocol.bandCount {
            let lowerFrequency = AudioEngineProtocol.minimumFrequency * pow(
                frequencyRatio,
                Double(band) / Double(AudioEngineProtocol.bandCount)
            )
            let upperFrequency = AudioEngineProtocol.minimumFrequency * pow(
                frequencyRatio,
                Double(band + 1) / Double(AudioEngineProtocol.bandCount)
            )
            let weightOffset = band * Self.fftBinCount
            var firstBin = Self.fftBinCount
            var lastBin = -1

            for bin in 0..<Self.fftBinCount {
                let binLower = max(0, (Double(bin) - 0.5) * binWidth)
                let binUpper = min(nyquist, (Double(bin) + 0.5) * binWidth)
                let overlap = min(upperFrequency, binUpper) - max(lowerFrequency, binLower)
                guard overlap > 0 else { continue }

                bandWeights[weightOffset + bin] = Float(overlap / (binUpper - binLower))
                firstBin = min(firstBin, bin)
                lastBin = bin
            }

            if lastBin >= firstBin {
                bandFirstBins[band] = firstBin
                bandBinCounts[band] = lastBin - firstBin + 1
            } else {
                bandFirstBins[band] = 0
                bandBinCounts[band] = 0
            }
        }
    }

    private func normalizedEnergy(_ rms: Double) -> Double {
        // Fixed soft compression preserves loud/quiet contrast without pumping
        // quiet passages up to full scale or clipping ordinary music to a wall.
        min(1, log1p(max(0, rms - Self.noiseFloor) * 20) / Self.normalization)
    }

    private func spectralBands(from ring: [Float]) -> [Double] {
        ring.withUnsafeBufferPointer { ringBuffer in
            hannWindow.withUnsafeBufferPointer { windowBuffer in
                fftInput.withUnsafeMutableBufferPointer { inputBuffer in
                    vDSP_vmul(
                        ringBuffer.baseAddress!.advanced(by: ringWriteIndex),
                        1,
                        windowBuffer.baseAddress!,
                        1,
                        inputBuffer.baseAddress!,
                        1,
                        vDSP_Length(Self.fftLength)
                    )
                }
            }
        }

        fftInput.withUnsafeBufferPointer { inputBuffer in
            fftReal.withUnsafeMutableBufferPointer { realBuffer in
                fftImaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    fftPower.withUnsafeMutableBufferPointer { powerBuffer in
                        var split = DSPSplitComplex(
                            realp: realBuffer.baseAddress!,
                            imagp: imaginaryBuffer.baseAddress!
                        )
                        inputBuffer.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self,
                            capacity: Self.fftLength / 2
                        ) { interleaved in
                            vDSP_ctoz(
                                interleaved,
                                2,
                                &split,
                                1,
                                vDSP_Length(Self.fftLength / 2)
                            )
                        }
                        vDSP_fft_zrip(
                            fftSetup,
                            &split,
                            1,
                            Self.fftLog2Length,
                            FFTDirection(FFT_FORWARD)
                        )

                        // vDSP's real forward FFT is 2x the conventional DFT.
                        // HANN_NORM gives the window unit RMS gain, so these
                        // factors make the one-sided bin powers sum to the
                        // windowed signal's correctly calibrated RMS squared.
                        let endpointScale = Float(
                            1 / (4 * Double(Self.fftLength * Self.fftLength))
                        )
                        powerBuffer[0] =
                            realBuffer[0] * realBuffer[0] * endpointScale
                        powerBuffer[Self.fftLength / 2] =
                            imaginaryBuffer[0] * imaginaryBuffer[0] * endpointScale

                        var interior = DSPSplitComplex(
                            realp: realBuffer.baseAddress!.advanced(by: 1),
                            imagp: imaginaryBuffer.baseAddress!.advanced(by: 1)
                        )
                        let interiorCount = vDSP_Length(Self.fftLength / 2 - 1)
                        vDSP_zvmags(
                            &interior,
                            1,
                            powerBuffer.baseAddress!.advanced(by: 1),
                            1,
                            interiorCount
                        )
                        var interiorScale = Float(
                            1 / (2 * Double(Self.fftLength * Self.fftLength))
                        )
                        vDSP_vsmul(
                            powerBuffer.baseAddress!.advanced(by: 1),
                            1,
                            &interiorScale,
                            powerBuffer.baseAddress!.advanced(by: 1),
                            1,
                            interiorCount
                        )
                    }
                }
            }
        }

        var bands = Array(repeating: 0.0, count: AudioEngineProtocol.bandCount)
        fftPower.withUnsafeBufferPointer { powerBuffer in
            bandWeights.withUnsafeBufferPointer { weightBuffer in
                for band in bands.indices {
                    let count = bandBinCounts[band]
                    guard count > 0 else { continue }

                    let firstBin = bandFirstBins[band]
                    var bandPower: Float = 0
                    vDSP_dotpr(
                        powerBuffer.baseAddress!.advanced(by: firstBin),
                        1,
                        weightBuffer.baseAddress!.advanced(
                            by: band * Self.fftBinCount + firstBin
                        ),
                        1,
                        &bandPower,
                        vDSP_Length(count)
                    )
                    bands[band] = normalizedEnergy(sqrt(Double(max(0, bandPower))))
                }
            }
        }
        return bands
    }

    func process(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        sampleRate: Double,
        endingAt timestamp: TimeInterval,
        emit: (AudioFrame) -> Void
    ) {
        guard channelCount > 0, frameCount > 0,
              sampleRate.isFinite,
              sampleRate >= Double(AudioEngineProtocol.framesPerSecond) else {
            return
        }
        if sampleRate != configuredSampleRate || channelCount != configuredChannelCount {
            configure(sampleRate: sampleRate, channelCount: channelCount)
        }
        let isStereo = channelCount > 1

        for frameIndex in 0..<frameCount {
            let leftSample = channels[0][frameIndex]
            leftRing[ringWriteIndex] = leftSample
            leftRing[ringWriteIndex + Self.fftLength] = leftSample

            let leftValue = Double(leftSample)
            leftSquares += leftValue * leftValue
            leftPeak = max(leftPeak, abs(leftValue))

            if isStereo {
                let rightSample = channels[1][frameIndex]
                rightRing[ringWriteIndex] = rightSample
                rightRing[ringWriteIndex + Self.fftLength] = rightSample
                let rightValue = Double(rightSample)
                rightSquares += rightValue * rightValue
                rightPeak = max(rightPeak, abs(rightValue))
            }

            ringWriteIndex += 1
            if ringWriteIndex == Self.fftLength {
                ringWriteIndex = 0
            }
            filledWindowFrames += 1
            guard filledWindowFrames == windowFrames else { continue }

            let leftBands = spectralBands(from: leftRing)
            let divisor = Double(windowFrames)
            let leftChannel = AudioChannelFrame(
                level: normalizedEnergy(sqrt(leftSquares / divisor)),
                peak: normalizedEnergy(leftPeak),
                bands: leftBands
            )
            let rightChannel: AudioChannelFrame
            if isStereo {
                rightChannel = AudioChannelFrame(
                    level: normalizedEnergy(sqrt(rightSquares / divisor)),
                    peak: normalizedEnergy(rightPeak),
                    bands: spectralBands(from: rightRing)
                )
            } else {
                rightChannel = leftChannel
            }

            filledWindowFrames = 0
            leftSquares = 0
            rightSquares = 0
            leftPeak = 0
            rightPeak = 0
            sequence &+= 1
            emit(AudioFrame(
                sequence: sequence,
                timestamp: timestamp - Double(frameCount - frameIndex - 1) / sampleRate,
                channels: [leftChannel, rightChannel]
            ))
        }
    }
}
