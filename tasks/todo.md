# termdeck 実装 TODO

計画: devkit 会話 2026-08-03（4画面 MRU 玉突き / リスト / フック連携 / 再起動復元 / 公開前提）

- [x] リポジトリ骨組み（git init / LICENSE / .gitignore）
- [x] lib/core.zsh — 状態ファイル・スロット・MRU・tmux ラッパー
- [x] deck new / stash モデル（deck-stash セッション + @deck_term）
- [x] deck open — MRU 玉突き（join/break/swap + window_layout 再適用）
- [x] tests/rotate-test.zsh — 使い捨て tmux サーバで 48 アサーション全緑
- [x] bin/deck-list — fzf リスト UI（Enter/クリックで開く・^N 新規・^S 復元切替・^K 削除）
- [x] hooks/deck-claude-status.sh — 状態 / 頼んだこと / 結果サマリの記録
- [x] deck restore / stop / keep / kill + LaunchAgent テンプレート
- [x] install.sh / README / tmux/deck.conf
- [x] devkit 統合（settings.json フック登録・bootstrap・エイリアス・docs・旧 agents スクリプト削除）
- [x] 実環境での動作確認（deck 起動 → new → claude 状態反映 → 復元）
- [x] コミット（termdeck 初回 / devkit 巻き取り分）
- [x] GitHub public リポジトリ作成と push（github.com/YoshikiKanayama/termdeck）
- [x] 状態表示の修正（2026-08-04）— フックだけでは「作業中」と「本当に入力待ち」が
      分離できず 🔴 要入力 が貼り付いていた。`capture-pane` でペイン末尾を読んで
      判定し、一覧は見張りで数秒ごとに追随させる
- [x] 止まっている理由を 🟠 承認待ち（Yes/No・プラン確認）と 🔵 質問
      （AskUserQuestion）に分割（2026-08-04）。判定の軸はモード行の有無
- [x] copy-mode 中のリストペインに ^R を送らない（2026-08-04）。tmux が横取りして
      検索プロンプト（画面下の黄色い帯）が開いてしまっていた
- [x] CI（2026-08-05）— macos-latest でテストを回す。Ubuntu の tmux 3.4 では
      remain-on-exit + pane-died の respawn が効かず落ちるため

## 見送り（将来）
- 結果サマリの本物の要約（claude -p を一段挟む。API コストが掛かるため）
- スマホへの Web Push 通知（ntfy 等。devkit の notify.sh 拡張として）
- Linux 対応の検証（systemd user unit での自動復元）
