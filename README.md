# termdeck

**バラバラに開いていたターミナルの窓を、1つの tmux 画面に集める。**
Claude Code などの AI エージェントを複数並行で使う人のための、数百行の zsh スクリプト集。

```
┌──────────────────┬──────────────────────────┐
│ リスト            │ ① いま使っているターミナル  │
│  ▶1 🟢 money-sim │    （最後に開いたもの）      │
│   2 🟡 portfolio │                          │
│   3 ⚪ devkit    ├──────────────────────────┤
│     🔴 blog      │ ② その前に使っていたもの     │
│     ⚫ sandbox   │                          │
├──────────────────┴──┐                       │
│ ③ さらにその前のもの   │                       │
└─────────────────────┴───────────────────────┘
```

- 左上の**リスト**には、各ターミナルの「リポジトリ / 状態 / 頼んだこと / 結果サマリ」が並ぶ
- リストで選ぶ（クリック or Enter）と右上に開く。前に開いていたものは右下→左下→非表示へ**玉突き**で下がる
- 非表示になってもターミナルは裏で生き続け、リストから選べばいつでも戻る
- ペイン境界はマウスでドラッグして自由にリサイズでき、**その配置は再起動後も保たれる**
- Mac を再起動しても、ログイン時に各ターミナルが `claude --resume` 付きで**自動復活**する

ブラウザにターミナルを自作する系のツール（xterm.js + WebSocket）と違い、
サーバもフロントエンドも持たない。全部 tmux の標準機能と zsh でできている。

## 思想

中央集権的な「エージェント管理ダッシュボード」ではない。
**独立した窓として使っていたターミナルを、1つの窓にまとめただけ**の状態を目指す。

- 各ターミナルはただの zsh。中で `claude` を対話的に使っても、使わなくてもいい
- 状態表示（作業中 / 要入力 / 入力待ち）や「頼んだこと」「結果サマリ」は、
  Claude Code の **hooks** が横から書き留めているだけで、ターミナル自体は何も特別ではない
- tmux を知らなくても使える。覚える操作は「リストで選ぶ」と `deck new` だけ

## 必要なもの

- macOS + zsh（LaunchAgent を使わないなら Linux でも動くはず・未検証）
- [tmux](https://github.com/tmux/tmux) / [jq](https://github.com/jqlang/jq) / [fzf](https://github.com/junegunn/fzf) — `brew install tmux jq fzf`
- [Claude Code](https://claude.com/claude-code)（任意。無くても「窓を集める」機能は動く）

## インストール

```bash
git clone https://github.com/YoshikiKanayama/termdeck.git ~/src/termdeck
cd ~/src/termdeck && zsh install.sh          # --with-tmux で最小 tmux 設定も導入
source ~/.zshrc
deck
```

`install.sh` がやるのは: エイリアス登録（`~/.zshrc`）、Claude Code フックのシンボリックリンク、
ログイン時自動復元の LaunchAgent 登録（`--no-launchd` でスキップ可）。

### フック登録（状態表示を使う場合）

`~/.claude/settings.json` の `hooks` に以下を追加する（既存のフックとは共存できる）:

```json
{
  "hooks": {
    "SessionStart": [{ "matcher": "startup|resume|clear|fork", "hooks": [
      { "type": "command", "command": "zsh ~/.claude/hooks/deck-claude-status.sh 2>/dev/null || true" }]}],
    "UserPromptSubmit": [{ "hooks": [
      { "type": "command", "command": "zsh ~/.claude/hooks/deck-claude-status.sh 2>/dev/null || true" }]}],
    "Stop": [{ "hooks": [
      { "type": "command", "command": "zsh ~/.claude/hooks/deck-claude-status.sh 2>/dev/null || true" }]}],
    "SessionEnd": [{ "hooks": [
      { "type": "command", "command": "zsh ~/.claude/hooks/deck-claude-status.sh 2>/dev/null || true" }]}],
    "Notification": [{ "matcher": "permission_prompt|idle_prompt|elicitation_dialog", "hooks": [
      { "type": "command", "command": "zsh ~/.claude/hooks/deck-claude-status.sh 2>/dev/null || true" }]}]
  }
}
```

## 使い方

```
deck              画面を開く（無ければ組み立て、再起動後は自動復元してから接続）
deck new [repo]   新しいターミナルを作る（~/src 配下から選ぶ。パス指定も可）
deck open <番号>  そのターミナルを右上に出す
deck stop <番号>  再起動後の復元対象から外す（「明示的に止める」操作）
deck keep <番号>  復元対象に戻す
deck kill <番号>  ターミナルを終了して記録も消す（確認あり）
deck status       一覧をテキストで表示
```

リスト上のキー: `Enter/ダブルクリック` 開く / `^N` 新規 / `^K` 削除 / `^S` 復元ON・OFF / `^R` 更新

ターミナルの中で `exit` してもペインは閉じない（新しいシェルが入り直す）。
枠と配置を守るためで、ターミナルを消す操作は `^K`（= `deck kill`）に一本化している。

日常はこれだけ:

1. ターミナルを開いて `deck`
2. `^N` でリポジトリを選んでターミナルを作り、中で `claude` を起動して仕事を頼む
3. 別の仕事はまた `^N`。画面から溢れたものはリストから呼び戻す
4. 離れるときはウィンドウを閉じるだけ（すべて裏で動き続ける）。戻ったらまた `deck`

## 状態アイコン

| 表示 | 意味 |
|---|---|
| 🟢 作業中 | claude がタスクを実行している。放っておいてよい |
| 🟠 承認待ち | ツール承認・プラン確認で止まっている。だいたい Yes を押すだけ |
| 🔵 質問 | claude が選択肢を出して聞いている。番号を選べば進む |
| 🔴 要入力 | 止まっているが種類までは読めなかった |
| 🟡 入力待ち | プロンプトに戻っている。文章を打つ必要がある |
| ⚪ シェル | claude を起動していないただのシェル |
| ⚫ 終了 | claude セッションが終了した |

状態は **claude の画面そのもの**（ペイン末尾）から読む。フックはイベントの瞬間しか
書けず、たとえば「承認に答えて作業が再開した」ことを知らせる手段が無いため、
状態が貼り付いて「作業中」と「止まっている」が見分けられなくなる。
画面を正にすればそこがズレない（読み取れないときはフックの記録に戻す）。

見分けの軸は**モード行**（`auto mode on` など）。ダイアログが開いている間はモード行が
隠れるので、まず「モード行が見える＝止まっていない」を確定させ、そのうえで
🔵 質問（`Enter to select` が出る）と 🟠 承認待ち（`Do you want to …?` / `Tab to amend`）
を分ける。すべて画面から確実に読める区別で、推測は入っていない。

なお Claude Code には「自由記述の入力欄」という独立した画面は無い。質問で
`Type something.` を選ぶとダイアログは閉じてただのプロンプトに戻るため、
そこからは 🟡 入力待ち になる。

一覧は数秒ごとに中身を見比べて、変わったときだけ描き直す。手動更新は `^R`。

「結果サマリ」は最後の応答の冒頭を写したもの（追加の API コストなし）。

## 再起動後の復元について

- 復活するのは **claude の会話履歴**（`claude --resume <session-id>`）。実行途中だった作業そのものは戻らない。履歴を見て「続けて」と頼めば再開できる
- 復元したくないターミナルは `deck stop <番号>`（リストなら `^S`）
- 自動復元を使わない場合も、`deck` と打てばその場で同じ復元が走る

## 仕組み（1分で）

- 画面 = tmux セッション `deck` の4ペイン。非表示のターミナルはデタッチ済みセッション `deck-stash` のウィンドウ
- 玉突き = `join-pane` / `break-pane` / `swap-pane`。リサイズ保持 = `window_layout` 文字列の保存と再適用
- 記録 = `~/.local/state/termdeck/` の JSON。Claude Code の hooks（`SessionStart` / `UserPromptSubmit` / `Stop` / `Notification`）が `TMUX_PANE` を鍵に書き込む（頼んだこと・結果サマリ・セッションID）
- 状態表示 = `capture-pane` でペイン末尾を読んで判定。読めないときだけ上の記録を使う
- 一覧の追随 = `deck-list` の裏で回る見張りが、表示が変わったときだけ fzf に reload を送る（間隔は `DECK_WATCH_INTERVAL`、既定 3 秒。デタッチ中は止まる）
- 自動復元 = LaunchAgent がログイン時に `deck restore` を実行

## アンインストール

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.termdeck.restore.plist
rm ~/Library/LaunchAgents/com.termdeck.restore.plist ~/.claude/hooks/deck-claude-status.sh
rm -rf ~/.local/state/termdeck ~/src/termdeck
# ~/.zshrc と ~/.claude/settings.json から termdeck の記述を削除
```

## テスト

```bash
zsh tests/rotate-test.zsh   # 使い捨て tmux サーバで玉突きロジックを検証
```

## ライセンス

MIT
