# 開発ガイド

## 基本方針

- Issueを変更の起点とし、背景、完了条件、判断を一か所に集める。
- `main`へ直接コミットせず、1つの目的に絞ったブランチとPull Requestを使う。
- 不具合修正には、可能な限り不具合を再現するテストを先に追加する。
- 音声取得、権限、AppKit UIの変更は、自動テストに加えて実機で確認する。
- 録音、会議内容、個人情報、認証情報、ローカルのビルド出力をコミットしない。

## 開発フロー

1. GitHub Issueを作成し、目的と完了条件を明確にする。
2. 最新の`main`から作業ブランチを作る。
3. 必要な範囲だけを変更し、テストを追加する。
4. ローカルでビルドとテストを実行する。
5. Pull Requestを作成し、Issueを`Closes #123`形式で関連付ける。
6. CIと必要な実機確認が成功してから`main`へマージする。

ブランチ名にはIssue番号と短い目的を含める。

```text
codex/12-support-24bit-pcm
codex/18-fix-segment-merge
```

## ローカル確認

```sh
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swift build
CLANG_MODULE_CACHE_PATH=.build/ModuleCache swift test
```

通常のmacOSアプリとして確認する場合は、アプリをパッケージして`/Applications`へインストールする。

```sh
Scripts/install-app.sh
```

## 完了条件

すべての変更で次を満たす。

- ビルドと自動テストが成功する。
- 新しい分岐や修正した不具合をテストで保護する。
- ユーザー向けの挙動や運用が変わる場合はREADMEまたは`docs/`を更新する。
- PRに変更理由、確認結果、リスク、戻し方を記載する。

音声取得、権限、デバイス、UIへ影響する変更では、さらに次を確認する。

- 対面モードで短い録音を行う。
- オンライン会議モードでシステム音声とマイク音声を録音する。
- 保存ファイルを実際に再生する。
- 対象となるmacOS、マイク、オーディオデバイスをPRへ記録する。

## GitHub CLI

GitHub上の操作には`gh`を使用する。

```sh
gh auth status
gh issue create
gh issue view 123
gh pr create
gh pr checks
```

認証が切れている場合は、作業者自身のGitHubアカウントで再認証する。

```sh
gh auth login -h github.com
```

## インシデント対応

録音不能、データ損失、権限ループなどの運用障害は、通常の不具合Issueより先に重要度と影響を評価する。詳しい手順は[インシデント対応ガイド](docs/incident-response.md)を参照する。
