# MeetingAudioCapture

Mac向けのメニューバー常駐型ミーティング録音アプリです。Zoom、Discord、Google Meet(Firefox)、Teamsなどのオンライン会議ではシステム音声とマイク音声を1本の音声ファイルへ保存します。対面モードではマイクのみを保存します。保存形式はM4A、WAV、MP3から選択できます。

## 対象環境

- Apple Silicon Mac
- macOS 15以降
- macOS Tahoe 26.4.1での利用を想定

## ビルド

Swiftのモジュールキャッシュをプロジェクト内に置くと、Codex環境でもビルドしやすくなります。

```sh
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swift build
```

通常のMacアプリとして起動する場合は、`.app` を生成します。

```sh
Scripts/package-app.sh
open .build/release/MeetingAudioCapture.app
```

権限確認を安定させたい開発時は、`/Applications` にインストールして起動します。

```sh
Scripts/install-app.sh
```

## 使い方

1. メニューバーの `REC` から録音モードを選びます。
2. 必要に応じてマイクを選びます。
3. `録音開始` を選びます。
4. macOSから求められたマイク権限と画面収録権限を許可します。
5. `録音停止` を選ぶと、選択した保存先に選択形式の音声ファイルが保存されます。`停止後に分割ファイルを結合` を有効にしている場合は、結合に成功すると `_merged` ファイルだけを残します。結合に失敗した場合は、結合前の `partNNN` ファイルを残します。

オンライン会議モードでは通知音やBGMも一緒に録音されます。内蔵スピーカー利用時は相手音声がマイクに回り込み、ASR品質が落ちる可能性があります。文字起こし重視ならイヤホンやヘッドセットの利用を推奨します。

MP3保存は一時M4Aを `ffmpeg -i input.m4a -ar 44100 -ab 128k output.mp3` 相当で変換します。`ffmpeg` が未導入の場合は録音停止時にエラーを表示します。M4A/WAVは追加ツールなしで保存できます。

## エラー対応

完了済みの機能追加メモは [docs/feature-notes.md](docs/feature-notes.md) にまとめています。想定している録音失敗ケースと復旧挙動は [docs/error-handling.md](docs/error-handling.md) を参照してください。

インシデントの重要度、初動、調査、終了条件は [docs/incident-response.md](docs/incident-response.md) にまとめています。

24-bit Integer PCM入力で録音が停止する問題の原因、対応内容、残る実機確認は [docs/investigation-24bit-integer-pcm-error.md](docs/investigation-24bit-integer-pcm-error.md) を参照してください。

## テスト

```sh
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swift test
```

自動テストでは、ファイル名、経過時間、設定保存、ミキサー、M4A/WAV/MP3出力、分割保存、結合、エラー文言を確認します。実機受け入れテストは完了済みです。

Issue、ブランチ、Pull Requestを使った開発手順と完了条件は [CONTRIBUTING.md](CONTRIBUTING.md) を参照してください。Pull RequestではGitHub Actionsがビルドとテストを自動実行します。

個人利用向けReleaseは、`Info.plist`と一致する`v*`タグをpushするとGitHub Actionsがテスト、パッケージ、ZIP・SHA-256生成、GitHub Release公開まで自動実行します。
