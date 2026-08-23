import AudioToolbox
import AVFAudio
import CoreMedia
import Foundation

public final class SampleBufferAudioConverter {
    public init() {}

    public func chunk(from sampleBuffer: CMSampleBuffer, source: AudioSourceKind) throws -> AudioChunk {
        guard CMSampleBufferIsValid(sampleBuffer) else {
            throw RecorderError.invalidBuffer("無効なCMSampleBufferです。")
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            return try AudioChunk(source: source, startTimeSeconds: timestamp(sampleBuffer), sampleRate: 48_000, channels: [])
        }

        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw RecorderError.unsupportedAudioFormat("音声フォーマット情報を取得できませんでした。")
        }

        let asbd = streamDescription.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw RecorderError.unsupportedAudioFormat("Linear PCM以外の入力フォーマットには未対応です。")
        }

        let channels = Int(asbd.mChannelsPerFrame)
        guard channels > 0 else {
            throw RecorderError.unsupportedAudioFormat("入力チャンネル数が0です。")
        }

        let audioBufferListPointer = try retainedAudioBufferList(from: sampleBuffer)
        defer {
            audioBufferListPointer.raw.deallocate()
        }

        let decoded = try decode(
            audioBufferList: UnsafeMutableAudioBufferListPointer(audioBufferListPointer.list),
            asbd: asbd,
            channels: channels,
            frameCount: frameCount
        )

        return try AudioChunk(
            source: source,
            startTimeSeconds: timestamp(sampleBuffer),
            sampleRate: asbd.mSampleRate,
            channels: decoded
        )
    }

    private func timestamp(_ sampleBuffer: CMSampleBuffer) -> Double {
        let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        if seconds.isFinite {
            return seconds
        }
        return ProcessInfo.processInfo.systemUptime
    }

    private typealias RetainedAudioBufferList = (
        raw: UnsafeMutableRawPointer,
        list: UnsafeMutablePointer<AudioBufferList>,
        blockBuffer: CMBlockBuffer
    )

    private func retainedAudioBufferList(from sampleBuffer: CMSampleBuffer) throws -> RetainedAudioBufferList {
        var sizeNeeded = 0
        var status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: nil
        )

        guard status == noErr, sizeNeeded > 0 else {
            throw RecorderError.invalidBuffer("AudioBufferListのサイズ取得に失敗しました: \(status)")
        }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: sizeNeeded,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?

        status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )

        guard status == noErr, let blockBuffer else {
            raw.deallocate()
            throw RecorderError.invalidBuffer("AudioBufferListの取得に失敗しました: \(status)")
        }

        // AudioBufferList内のmDataはCMBlockBufferが所有するため、デコード完了まで保持する。
        return (raw, list, blockBuffer)
    }

    private func decode(
        audioBufferList: UnsafeMutableAudioBufferListPointer,
        asbd: AudioStreamBasicDescription,
        channels: Int,
        frameCount: Int
    ) throws -> [[Float]] {
        let flags = asbd.mFormatFlags
        let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        let bitsPerChannel = Int(asbd.mBitsPerChannel)
        let bytesPerFrame = Int(asbd.mBytesPerFrame)

        guard bytesPerFrame > 0 else {
            throw RecorderError.unsupportedAudioFormat("PCMの1フレームあたりのバイト数が0です。")
        }

        var decoded = Array(
            repeating: Array(repeating: Float(0), count: frameCount),
            count: channels
        )

        if isNonInterleaved {
            let sampleDecoder = try LinearPCMSampleDecoder(
                bitsPerChannel: bitsPerChannel,
                bytesPerSample: bytesPerFrame,
                formatFlags: flags
            )

            guard audioBufferList.count >= channels else {
                throw RecorderError.invalidBuffer("非インターリーブPCMのチャンネルバッファが不足しています。")
            }

            for channel in 0..<channels {
                let buffer = audioBufferList[channel]
                guard let data = buffer.mData else {
                    throw RecorderError.invalidBuffer("非インターリーブPCMのデータが空です。")
                }
                let byteCount = Int(buffer.mDataByteSize)
                try validateBufferSize(byteCount, frameCount: frameCount, bytesPerFrame: bytesPerFrame)
                let bytes = UnsafeRawBufferPointer(start: data, count: byteCount)

                for frame in 0..<frameCount {
                    decoded[channel][frame] = try sampleDecoder.decode(
                        from: bytes,
                        offset: frame * bytesPerFrame
                    )
                }
            }
        } else {
            guard bytesPerFrame % channels == 0 else {
                throw RecorderError.unsupportedAudioFormat(
                    "インターリーブPCMのフレーム幅をチャンネル数で分割できません。"
                )
            }
            let bytesPerSample = bytesPerFrame / channels
            let sampleDecoder = try LinearPCMSampleDecoder(
                bitsPerChannel: bitsPerChannel,
                bytesPerSample: bytesPerSample,
                formatFlags: flags
            )

            guard let buffer = audioBufferList.first, let data = buffer.mData else {
                throw RecorderError.invalidBuffer("インターリーブPCMのデータが空です。")
            }
            let byteCount = Int(buffer.mDataByteSize)
            try validateBufferSize(byteCount, frameCount: frameCount, bytesPerFrame: bytesPerFrame)
            let bytes = UnsafeRawBufferPointer(start: data, count: byteCount)

            for frame in 0..<frameCount {
                for channel in 0..<channels {
                    decoded[channel][frame] = try sampleDecoder.decode(
                        from: bytes,
                        offset: frame * bytesPerFrame + channel * bytesPerSample
                    )
                }
            }
        }

        return decoded
    }

    private func validateBufferSize(
        _ byteCount: Int,
        frameCount: Int,
        bytesPerFrame: Int
    ) throws {
        let (requiredBytes, didOverflow) = frameCount.multipliedReportingOverflow(by: bytesPerFrame)
        guard !didOverflow, byteCount >= requiredBytes else {
            throw RecorderError.invalidBuffer(
                "PCMバッファのサイズが不足しています: \(byteCount) / \(didOverflow ? -1 : requiredBytes) bytes"
            )
        }
    }
}
