# Keyhint

Homerow / Vimac 風に、キーボードだけで macOS の画面要素をクリック・スクロールする常駐アプリ。依存なしの SwiftPM。

## 使い方

| キー | 動作 |
| --- | --- |
| ⌘⇧F | ヒントモード。ラベルを打つとその要素を押す |
| ラベルの最後の文字を Shift 付きで | ⌘クリック(リンクを新しいタブで開く) |
| ラベルの最後の文字を Option 付きで | 右クリック |
| ⌘⇧J | スクロールモード。j/k/h/l、d/u で半ページ、g/G で先頭/末尾、Esc で抜ける |
| スクロールモード中の 1〜9・0 / Tab | スクロールする領域を切り替える(青枠が対象) |

## ビルド

```sh
./scripts/bundle.sh
open build/Keyhint.app
```

初回はシステム設定 > プライバシーとセキュリティ > アクセシビリティで Keyhint を許可する。
ad-hoc 署名のため、再ビルドするたびに許可を付け直す(一度リストから削除して追加し直す)。

## 仕組み

- 画面ごとの最前面ウィンドウ(`CGWindowList` で特定)の AX ツリーを並列に走査し、ボタン・リンク・入力欄などを集める
- スクロール領域は AXScrollArea と、Web 内のリスト・DOM クラス名に scroll を含む要素から推定する
- Web 領域(AXWebArea)は `AXUIElementsForSearchPredicate` でまとめて検索する
- Chrome / Electron には `AXManualAccessibility` を立てて AX ツリーを作らせる
- ラベル確定時は `AXPress`、効かなければ要素の中心をクリックする

Web 領域の検索方法と `AXManualAccessibility` は [vimac](https://github.com/dexterleng/vimac) を参考にした(コードは流用していない)。
