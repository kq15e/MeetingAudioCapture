# 24-bit Integer PCM エラー調査

## 概要

2026-08-23 に、録音開始後に次のエラーが表示される事象を調査した。

> 音声処理に失敗しました
>
> 未対応のInteger PCMビット深度です: 24

直接原因は、入力された Linear PCM のビット深度が 24 bit だった一方、`SampleBufferAudioConverter` の整数 PCM デコーダーが 16 bit と 32 bit だけに対応していることである。権限、保存形式、保存先の問題ではない。

入力が 24 bit になること自体は不正ではない。録音処理が入力フォーマットを 16/32 bit に固定または標準化しておらず、OS・マイク・オーディオドライバーが返したフォーマットをアプリ独自のデコーダーへ直接渡していることが、互換性問題の本質である。

## 影響

- 24-bit signed integer Linear PCM を返す入力が一つでもあると録音が失敗する。
- 失敗は録音開始処理ではなく、最初の該当音声バッファを処理した時点で発生する。
- オンライン会議モードではシステム音声とマイク音声の両方が同じ変換処理を通るため、どちらが 24 bit でも失敗する。
- 対面モードではマイク音声が同じ変換処理を通るため、選択したマイクが 24 bit を返すと失敗する。
- ランタイムエラー処理によって録音は停止し、書き込み済みの分割ファイルがあれば閉じて残す。ただし、発生が早い場合は有用な録音が残らない可能性がある。

## コード上の根拠

### 1. 例外の発生箇所

`Sources/MeetingAudioCaptureCore/SampleBufferAudioConverter.swift` の `sample` は、Float PCM では 32/64 bit、Integer PCM では 16/32 bit だけを処理する。

```swift
switch bitsPerChannel {
case 16:
    // Int16 としてデコード
case 32:
    // Int32 としてデコード
default:
    throw RecorderError.unsupportedAudioFormat(
        "未対応のInteger PCMビット深度です: \(bitsPerChannel)"
    )
}
```

スクリーンショットの詳細メッセージはこの `default` からしか生成されない。したがって、次の条件まではコードとエラー文から確定できる。

1. `CMSampleBuffer` のフォーマット ID は Linear PCM だった。
2. フォーマットフラグは signed integer を示していた。
3. `mBitsPerChannel` は 24 だった。
4. デコーダーの対応表に 24 bit がないため `unsupportedAudioFormat` が送出された。

### 2. 入力フォーマットが標準化されていない

オンライン会議モードの `SCStreamConfiguration` では `sampleRate` と `channelCount` を指定しているが、Integer/Float やビット深度は指定していない。対面モードの `AVCaptureAudioDataOutput` にも出力音声フォーマットの指定や変換処理はない。

その結果、取得された `CMSampleBuffer` の `AudioStreamBasicDescription` をアプリがそのまま解釈する。デバイス、仮想オーディオドライバー、OS の出力形式が変われば、アプリに渡るビット深度も変わり得る。

### 3. 24 bit は単純な分岐追加だけでは安全に扱えない

24-bit PCM は、1サンプルを3バイトに詰める形式だけでなく、4バイトの格納領域に配置される形式もあり得る。正しい解釈には少なくとも次の ASBD 情報が必要になる。

- `mBytesPerFrame` と `mBytesPerPacket`
- `kAudioFormatFlagIsPacked`
- `kAudioFormatFlagIsAlignedHigh`
- `kAudioFormatFlagIsBigEndian`
- インターリーブ／非インターリーブ

現在の実装は `mBitsPerChannel` から Swift の型を選び、連続した配列として読むため、上記の格納方法を考慮していない。したがって、`case 24` を足して常に3バイトずつ読む修正では、一部の入力で誤読や範囲外アクセスを起こすおそれがある。

## 発生経路

```text
ScreenCaptureKit（システム音声／マイク）
    または AVCaptureSession（マイク）
                 ↓
          CMSampleBuffer
                 ↓
 SampleBufferAudioConverter.chunk
                 ↓
 ASBD: Linear PCM / signed integer / 24 bit
                 ↓
 sample の対応表は 16/32 bit のみ
                 ↓
 unsupportedAudioFormat
                 ↓
 録音停止 → failed 状態 → エラーダイアログ
```

## 「最近」発生するようになった可能性

24-bit 非対応コードは初期実装から存在し、直近の変更で導入されたものではない。履歴上、`SampleBufferAudioConverter` の実質的な実装は 2026-07-13 の初期コミットから変わっていない。

したがって、最近発生し始めたのであれば、アプリ側の新しい回帰より、次のような実行環境の変化で潜在的な制約が表面化した可能性が高い。

- 使用するマイク、オーディオインターフェース、ヘッドセットを変更した。
- macOS の「サウンド」または「Audio MIDI 設定」で入力装置やフォーマットを変更した。
- 仮想オーディオデバイスやそのドライバーを追加・更新した。
- macOS 更新後にキャプチャ API が返すフォーマットが変わった。
- アプリ内で選択されているマイクが以前と変わった。

ただし、現在のエラーログには `AudioSourceKind`、デバイス ID、ASBD 全フィールドが残らないため、今回のスクリーンショットだけでは、24-bit バッファがシステム音声とマイク音声のどちらから来たかは確定できない。

## 暫定回避策

コードを修正するまで、次の順で入力を 16-bit または 32-bit PCM に変えられるか確認する。

1. アプリで別のマイク（まず内蔵マイク）を選んで録音する。
2. macOS の「Audio MIDI 設定」で対象入力デバイスのフォーマットを確認し、選択可能なら 16-bit または 32-bit に変更する。
3. 仮想オーディオデバイスを使用している場合は、物理デバイスへ切り替えて再試行する。
4. オンライン会議モードだけで失敗するか、対面モードでも失敗するかを比較する。対面モードでも失敗する場合はマイク経路が有力である。

出力形式（M4A/WAV/MP3）の変更では回避できない。失敗は、出力ファイルへ書き込む前の入力 PCM デコードで起きるためである。

## 恒久対応案

推奨は、入力 PCM をアプリ側で手作業で全形式デコードするのではなく、AVFoundation / AudioToolbox の変換機構を使い、早い段階で共通の Float32 PCM に正規化することである。

対応時には次を含める。

1. 入力 ASBD から `AVAudioFormat` を作成する。
2. `AVAudioConverter` などで、ミキサーが扱う Float32 PCM へ変換する。
3. 変換前に source、デバイス識別情報、ASBD の主要フィールドとフラグを診断ログへ残す。
4. 24-bit packed、24-in-32、interleaved、non-interleaved のテスト用 `CMSampleBuffer` を用意する。
5. 16/32-bit の既存入力に回帰がないこと、クリッピング境界（最小値、0、最大値）の正規化結果を確認する。

独自デコーダーを維持する場合は、24 bit の符号拡張だけでなく、`mBytesPerFrame`、配置、エンディアン、フォーマットフラグを検証してから読み出す必要があるため、実装とテストの範囲が広くなる。

## 対応結果

Issue #6 の対応では、既存のキャプチャ経路を維持し、PCMサンプルの解釈を`LinearPCMSampleDecoder`へ分離した。次の形式を入力フォーマット情報に基づいて処理する。

- packed signed integer PCM（8〜32 bit。24 bitは3バイト）
- 24-in-32を含む、格納幅より有効ビット数が小さいsigned integer PCM
- 上位アラインと下位アライン
- little endianとbig endian
- Float32とFloat64
- interleavedとnon-interleavedのフレームストライド

また、必要バイト数より短い入力を読み出す前に`invalidBuffer`として拒否し、`AudioBufferList`のデータを所有する`CMBlockBuffer`をデコード完了まで保持するようにした。

自動テストでは、24-bit packedの最小値・0・最大値、big endian、24-in-32の上位／下位アライン、既存16-bit入力、範囲外アクセス、矛盾したpacked指定を確認する。

### 残る確認事項

自動テストはPCMサンプルの解釈と安全性を検証するが、問題を報告した実デバイスが返す`CMSampleBuffer`そのものは入手できていない。マージ後も、対象デバイスまたは同等の24-bit入力環境で次を実機確認する必要がある。

1. 対面モードで録音を開始・停止できる。
2. オンライン会議モードでマイク音声とシステム音声を保存できる。
3. 保存ファイルを再生し、無音、極端な音量、ノイズ、左右チャンネルの異常がない。
4. 可能なら診断時のASBDと期待した24-bit格納形式が一致する。

## 追加調査で取得すべき情報

修正前に発生元を特定する場合は、個々の受信バッファについて次を記録する。音声データ本体は記録しない。

- 録音モードと `AudioSourceKind`
- 選択マイクの ID と名称
- `mFormatID`, `mFormatFlags`
- `mSampleRate`, `mChannelsPerFrame`, `mBitsPerChannel`
- `mBytesPerFrame`, `mFramesPerPacket`, `mBytesPerPacket`
- `AudioBufferList` のバッファ数と各 `mDataByteSize`

これにより、問題の入力元と「packed 24 bit」か「24-in-32」かを安全に判定できる。

## 結論

本事象の根本原因は、正常に到着した可能性のある24-bit signed integer PCMを、アプリの入力変換層が未対応形式として拒否する実装上の制約であった。Issue #6では24-bitの代表的な格納形式をFloatへ正規化できるようにした。自動テスト上の対応は完了しているが、障害が起きた実デバイスでの録音確認までは未完了である。
