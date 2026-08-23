import AudioToolbox
import Testing
@testable import MeetingAudioCaptureCore

@Suite
struct LinearPCMSampleDecoderTests {
    @Test
    func decodesPacked24BitLittleEndianBoundaries() throws {
        let decoder = try LinearPCMSampleDecoder(
            bitsPerChannel: 24,
            bytesPerSample: 3,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        )

        let bytes: [UInt8] = [
            0x00, 0x00, 0x80,
            0x00, 0x00, 0x00,
            0xFF, 0xFF, 0x7F
        ]

        let values = try bytes.withUnsafeBytes { buffer in
            [
                try decoder.decode(from: buffer, offset: 0),
                try decoder.decode(from: buffer, offset: 3),
                try decoder.decode(from: buffer, offset: 6)
            ]
        }

        #expect(values == [-1, 0, 1])
    }

    @Test
    func decodesPacked24BitBigEndian() throws {
        let decoder = try LinearPCMSampleDecoder(
            bitsPerChannel: 24,
            bytesPerSample: 3,
            formatFlags: kAudioFormatFlagIsSignedInteger
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsBigEndian
        )
        let bytes: [UInt8] = [0x40, 0x00, 0x00]

        let value = try bytes.withUnsafeBytes { buffer in
            try decoder.decode(from: buffer, offset: 0)
        }

        #expect(abs(value - 0.5) < 0.000_001)
    }

    @Test
    func decodes24BitAlignedHighIn32BitContainer() throws {
        let decoder = try LinearPCMSampleDecoder(
            bitsPerChannel: 24,
            bytesPerSample: 4,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsAlignedHigh
        )
        let bytes: [UInt8] = [0x00, 0x00, 0x00, 0x40]

        let value = try bytes.withUnsafeBytes { buffer in
            try decoder.decode(from: buffer, offset: 0)
        }

        #expect(abs(value - 0.5) < 0.000_001)
    }

    @Test
    func decodes24BitAlignedLowIn32BitContainer() throws {
        let decoder = try LinearPCMSampleDecoder(
            bitsPerChannel: 24,
            bytesPerSample: 4,
            formatFlags: kAudioFormatFlagIsSignedInteger
        )
        let bytes: [UInt8] = [0x00, 0x00, 0xC0, 0xAA]

        let value = try bytes.withUnsafeBytes { buffer in
            try decoder.decode(from: buffer, offset: 0)
        }

        #expect(abs(value - (-0.5)) < 0.000_001)
    }

    @Test
    func preservesExisting16BitIntegerSupport() throws {
        let decoder = try LinearPCMSampleDecoder(
            bitsPerChannel: 16,
            bytesPerSample: 2,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        )
        let bytes: [UInt8] = [0xFF, 0x7F]

        let value = try bytes.withUnsafeBytes { buffer in
            try decoder.decode(from: buffer, offset: 0)
        }

        #expect(value == 1)
    }

    @Test
    func rejectsOutOfBoundsSample() throws {
        let decoder = try LinearPCMSampleDecoder(
            bitsPerChannel: 24,
            bytesPerSample: 3,
            formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
        )
        let bytes: [UInt8] = [0x00, 0x00]

        #expect(throws: RecorderError.self) {
            try bytes.withUnsafeBytes { buffer in
                try decoder.decode(from: buffer, offset: 0)
            }
        }
    }

    @Test
    func rejectsPackedFormatWithPadding() {
        #expect(throws: RecorderError.self) {
            try LinearPCMSampleDecoder(
                bitsPerChannel: 24,
                bytesPerSample: 4,
                formatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            )
        }
    }
}
