# Next Action Plan

## Goal

MeetingAudioCapture にアプリアイコンを追加し、生成される `.app` バンドルで Finder / Dock / アプリ一覧に正式なアイコンが表示される状態にする。

## Icon Direction

- モチーフは「ミーティング音声の録音」と「Macメニューバー常駐アプリ」。
- 小さいサイズでも判別しやすいよう、抽象的なマイク、音声波形、録音ドットを中心にする。
- 色は落ち着いた濃紺ベースに、音声波形のシアン、録音状態を示す赤をアクセントに使う。
- 文字や細かいラベルは入れない。

## Implementation Steps

1. `Resources/AppIcon.iconset` を生成する。
2. `iconutil` で `Resources/AppIcon.icns` を作成する。
3. `Resources/Info.plist` に `CFBundleIconFile` を追加する。
4. `Scripts/package-app.sh` で `Contents/Resources/AppIcon.icns` をコピーする。
5. `Scripts/package-app.sh` と `swift test` を実行して確認する。

## Notes

- 初回はプログラム生成のベクター風アイコンで進める。
- 将来、配布用にブランド調整したい場合は `Resources/AppIcon.iconset` の元画像を差し替えればよい。
- 実機受け入れテストは完了済みのため、この作業ではパッケージ生成とバンドル内アイコン設定の確認を完了条件にする。
