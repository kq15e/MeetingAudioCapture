import AudioToolbox
import Foundation

struct LinearPCMSampleDecoder {
    let bitsPerChannel: Int
    let bytesPerSample: Int
    let isFloat: Bool
    let isBigEndian: Bool
    let isAlignedHigh: Bool

    init(
        bitsPerChannel: Int,
        bytesPerSample: Int,
        formatFlags: AudioFormatFlags
    ) throws {
        let isFloat = formatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInteger = formatFlags & kAudioFormatFlagIsSignedInteger != 0

        guard isFloat != isSignedInteger else {
            throw RecorderError.unsupportedAudioFormat(
                "FloatまたはSigned Integerのどちらか一方を指定したPCMフォーマットが必要です。"
            )
        }
        guard bitsPerChannel > 0, bytesPerSample > 0 else {
            throw RecorderError.unsupportedAudioFormat("PCMのビット深度または格納幅が不正です。")
        }
        guard bitsPerChannel <= bytesPerSample * 8 else {
            throw RecorderError.unsupportedAudioFormat(
                "PCMのビット深度が格納幅を超えています: \(bitsPerChannel) bit / \(bytesPerSample) bytes"
            )
        }

        if isFloat {
            guard (bitsPerChannel == 32 && bytesPerSample == 4)
                    || (bitsPerChannel == 64 && bytesPerSample == 8) else {
                throw RecorderError.unsupportedAudioFormat(
                    "未対応のFloat PCM形式です: \(bitsPerChannel) bit / \(bytesPerSample) bytes"
                )
            }
        } else {
            guard (8...32).contains(bitsPerChannel), bytesPerSample <= 4 else {
                throw RecorderError.unsupportedAudioFormat(
                    "未対応のInteger PCM形式です: \(bitsPerChannel) bit / \(bytesPerSample) bytes"
                )
            }

            let isPacked = formatFlags & kAudioFormatFlagIsPacked != 0
            guard !isPacked || bitsPerChannel == bytesPerSample * 8 else {
                throw RecorderError.unsupportedAudioFormat(
                    "Packed PCMのビット深度と格納幅が一致しません。"
                )
            }
        }

        self.bitsPerChannel = bitsPerChannel
        self.bytesPerSample = bytesPerSample
        self.isFloat = isFloat
        self.isBigEndian = formatFlags & kAudioFormatFlagIsBigEndian != 0
        self.isAlignedHigh = formatFlags & kAudioFormatFlagIsAlignedHigh != 0
    }

    func decode(from bytes: UnsafeRawBufferPointer, offset: Int) throws -> Float {
        guard offset >= 0, offset <= bytes.count - bytesPerSample else {
            throw RecorderError.invalidBuffer("PCMサンプルが入力バッファの範囲外です。")
        }

        let rawValue = readUnsigned(from: bytes, offset: offset)
        if isFloat {
            switch bitsPerChannel {
            case 32:
                return Float(bitPattern: UInt32(truncatingIfNeeded: rawValue))
            case 64:
                return Float(Double(bitPattern: rawValue))
            default:
                preconditionFailure("Float PCM format was validated during initialization")
            }
        }

        let containerBits = bytesPerSample * 8
        let alignmentShift = isAlignedHigh ? containerBits - bitsPerChannel : 0
        let valueMask = (UInt64(1) << bitsPerChannel) - 1
        let alignedValue = (rawValue >> alignmentShift) & valueMask
        let signBit = UInt64(1) << (bitsPerChannel - 1)
        let signedValue: Int64
        if alignedValue & signBit == 0 {
            signedValue = Int64(alignedValue)
        } else {
            signedValue = Int64(alignedValue) - Int64(UInt64(1) << bitsPerChannel)
        }

        let maximumPositive = Float((UInt64(1) << (bitsPerChannel - 1)) - 1)
        return max(-1, Float(signedValue) / maximumPositive)
    }

    private func readUnsigned(from bytes: UnsafeRawBufferPointer, offset: Int) -> UInt64 {
        if isBigEndian {
            return (0..<bytesPerSample).reduce(UInt64(0)) { value, byteOffset in
                (value << 8) | UInt64(bytes[offset + byteOffset])
            }
        }

        return (0..<bytesPerSample).reduce(UInt64(0)) { value, byteOffset in
            value | (UInt64(bytes[offset + byteOffset]) << (byteOffset * 8))
        }
    }
}
