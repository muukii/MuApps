# Verse App Store メタデータ管理

このディレクトリには、Verse の App Store Connect に登録するメタデータを管理しています。
Tinycurve のメタデータは
[`Apps/Journal/metadata/`](../Apps/Journal/metadata/) に分離しています。
Färg のメタデータは
[`Apps/Farg/metadata/`](../Apps/Farg/metadata/) に分離しています。

## 📁 構造

```
metadata/
├── en/
│   └── app-store.md    # 英語版
├── ja/
│   └── app-store.md    # 日本語版
└── README.md
```

## 📝 メタデータの項目

各`app-store.md`には以下の項目が含まれています：

| 項目 | 文字数制限 | 説明 |
|------|-----------|------|
| App Name | 30文字 | アプリ名 |
| Subtitle | 30文字 | サブタイトル（検索結果に表示） |
| Keywords | 100文字 | 検索用キーワード（カンマ区切り） |
| Promotional Text | 170文字 | プロモーション文（アプリ更新なしで変更可能） |
| Description | 4,000文字 | アプリの詳細説明 |

## ✏️ 編集方法

1. 該当する言語フォルダのMarkdownファイルを開く
2. 各セクションの内容を編集
3. 文字数制限を確認
4. 変更をコミット

```bash
# 編集
vi metadata/ja/app-store.md

# コミット
git add metadata/
git commit -m "Update Japanese app description"
git push
```

## 📤 App Store Connectへの登録方法

1. [App Store Connect](https://appstoreconnect.apple.com/)にログイン
2. 該当アプリを選択
3. 「App情報」または「バージョン情報」タブを開く
4. 言語を選択
5. `app-store.md`の各セクションをコピー＆ペースト

## 🌍 新しい言語を追加する場合

```bash
# 例: 韓国語を追加
mkdir metadata/ko
cp metadata/en/app-store.md metadata/ko/
# その後、metadata/ko/app-store.mdを翻訳
```

主要な言語コード：
- `en`: 英語
- `ja`: 日本語
- `ko`: 韓国語
- `zh-Hans`: 簡体字中国語
- `zh-Hant`: 繁体字中国語

## 💡 ヒント

- **Promotional Text**は、アプリの更新なしに変更できるため、期間限定のプロモーションやキャンペーンに最適です
- **Keywords**は、App Storeの検索最適化（ASO）に重要なので、定期的に見直しましょう
- **Description**の最初の数行は検索結果でも表示されるため、特に重要です
