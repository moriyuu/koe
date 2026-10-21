# Koe

fn キーを押している間だけ録音し、離すと文字起こししてカーソル位置に貼り付ける macOS のメニューバーアプリ

文字起こしには xAI の STT API（`grok-voice-transcribe-2.0`）を使う

## 使い方

- fn を押しながら話す → 離すと文字起こし結果が貼り付けられる
- fn を 0.3 秒未満で離したとき、fn+矢印などのショートカットを押したときは録音を捨てる
- メニューバーのアイコンからも録音の開始/停止ができる
- 入力中のキャレットの右に、録音中は赤い点、文字起こし中はスピナーが出る（キャレット位置を返さないアプリでは出ない）

アイコンの状態

| アイコン | 状態 |
| --- | --- |
| mic | 待機中 |
| mic.fill | 録音中 |
| ellipsis | 文字起こし中 |
| exclamationmark.triangle | エラー（ホバーで内容を表示） |

## セットアップ

1. xAI の API キーを置く

   ```bash
   mkdir -p ~/.config/koe && echo "xai-..." > ~/.config/koe/api_key
   ```

2. ビルドする（`~/Applications/Koe.app` ができる）。`--restart` をつけると、動いている Koe を終了してからビルドし、ビルド後に起動する

   ```bash
   ./build.sh --restart
   ```

3. `Koe.app` を起動し、マイクとアクセシビリティを許可する
   - アクセシビリティは貼り付け（⌘V の送信）に必要

`build.sh` はキーチェーンにある最初の `Apple Development` 証明書で署名する。別の証明書を使うときは `KOE_SIGN_IDENTITY` で指定する

```bash
KOE_SIGN_IDENTITY="Apple Development: Your Name (XXXXXXXXXX)" ./build.sh
```

証明書がない場合はアドホック署名になり、再ビルドのたびにアクセシビリティの許可がやり直しになる。Xcode で Apple ID にサインインすると無料で `Apple Development` 証明書を作れる

## 設定

`~/.config/koe/` に置く。メニューの「設定フォルダを開く」から開ける

| ファイル | 内容 |
| --- | --- |
| `api_key` | xAI の API キー（必須） |
| `keyterms.txt` | 認識させたい固有名詞などを1行に1つ（任意）。100語まで、1語50文字まで（xAI の上限）。メニューの「辞書を編集…」からも編集できる |

## 制限

- 言語は日本語固定
- 貼り付け後にクリップボードを復元するのは文字列だけ。画像などをコピーしていた場合は消える

## デバッグ

エラーと文字起こし結果は `$TMPDIR/koe.log` に出る

```bash
tail -f "$TMPDIR/koe.log"
```
