# termdeck 実装 TODO

計画: devkit 会話 2026-08-03（4画面 MRU 玉突き / リスト / フック連携 / 再起動復元 / 公開前提）

- [x] リポジトリ骨組み（git init / LICENSE / .gitignore）
- [x] lib/core.zsh — 状態ファイル・スロット・MRU・tmux ラッパー
- [x] deck new / stash モデル（deck-stash セッション + @deck_term）
- [x] deck open — MRU 玉突き（join/break/swap + window_layout 再適用）
- [x] tests/rotate-test.zsh — 使い捨て tmux サーバで 26 アサーション全緑
- [x] bin/deck-list — fzf リスト UI（Enter/クリックで開く・^N 新規・^S 復元切替・^K 削除）
- [x] hooks/deck-claude-status.sh — 状態 / 頼んだこと / 結果サマリの記録
- [x] deck restore / stop / keep / kill + LaunchAgent テンプレート
- [x] install.sh / README / tmux/deck.conf
- [ ] devkit 統合（settings.json フック登録・bootstrap・エイリアス・docs・旧 agents スクリプト削除）
- [ ] 実環境での動作確認（deck 起動 → new → claude 状態反映 → 復元）
- [ ] コミット（termdeck 初回 / devkit 巻き取り分）※ユーザー確認後
- [ ] GitHub public リポジトリ作成と push ※ユーザー確認後

## 見送り（将来）
- 結果サマリの本物の要約（claude -p を一段挟む。API コストが掛かるため）
- スマホへの Web Push 通知（ntfy 等。devkit の notify.sh 拡張として）
- Linux 対応の検証（systemd user unit での自動復元）
