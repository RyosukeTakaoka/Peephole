# モデレーション対応 運用手順書（Runbook）

対象: `reports`（通報）/ `blocks`（ブロック）への 24 時間以内の対応。
Apple App Review（Guideline 1.2）向けに、「通報・ブロックは開発者へ自動メール通知され、
24 時間以内に内容確認とコンテンツ削除・アカウント措置を行う」運用を実施するための手順。

関連: `docs/review-fix-design.md` §2.5 / §8 T17、`scripts/moderation-notifier/`、
`.github/workflows/moderation-notifier.yml`

---

## 1. 通知の仕組み（自動）

- GitHub Actions（`.github/workflows/moderation-notifier.yml`）が **30 分間隔** で
  `scripts/moderation-notifier` を実行する。
- `reports` / `blocks` のうち `notified == false` のドキュメントを検出し、
  該当があれば **cjie46251@gmail.com** へメールを送信する。
- メール本文には reportId / blockId、対象ユーザーID、通報理由、Firebase コンソールへの
  直リンクが含まれる。
- 送信成功後、該当ドキュメントの `notified` を `true`、`notifiedAt` を送信日時に更新する
  （Admin SDK 経由のためセキュリティルールの対象外）。
- 未通知ドキュメントが 0 件の場合はメールを送信しない。

---

## 2. 通知受信時の対応手順（24 時間以内）

1. **メール受信**: 件名「Peephole: 未対応の通報・ブロックがあります」のメールを確認する。
2. **Firebase コンソールで対象を確認**: メール本文のリンクから該当ドキュメントを開く。
   - 通報（`reports`）の場合: `targetType`（post / user）、`reason`、`detail`、
     `targetPostId` / `targetUserId` を確認し、該当の投稿・ユーザーの内容を確認する。
   - ブロック（`blocks`）の場合: `blockerId` / `blockedId` を確認する。ブロック自体は
     ユーザー間の措置のため、原則として運営側の追加対応は不要だが、繰り返しブロックされる
     ユーザーがいないか等の傾向確認に利用する。
3. **対応を実施する**（通報の場合。内容に応じて以下から選択）:
   - **投稿を非表示にする**: `posts` コレクションの該当ドキュメントを開き、
     `isHidden` フィールドを `true` に変更する（コンソールでの手動編集。
     クライアントからは変更できないルールになっている）。
   - **投稿を削除する**: 特に悪質な場合は `posts` ドキュメント自体を削除する。
   - **アカウントへの措置**: 悪質なユーザーに対しては、Firebase Authentication
     コンソールから該当アカウントを無効化 / 削除する。`users/{uid}` ドキュメントも
     あわせて削除する（`hiddenPosts` サブコレクション、当該ユーザーが関わる
     `follows` / `followRequests` / `blocks` の整合性はベストエフォートで確認する。
     厳密なカスケード削除はユーザー本人によるアプリ内アカウント削除機能で行われる）。
   - 対応不要（誤通報・軽微）と判断した場合は、記録のみ残し次のステップへ進む。
4. **`reports.status` を更新する**: 対応が完了したら、該当 `reports` ドキュメントの
   `status` を `"actioned"`（措置済み）または `"reviewed"`（確認済み・対応不要）に
   コンソールから手動で更新する。
5. **記録**: 対応内容・日時を任意の記録手段（スプレッドシート等）に残しておくことを推奨する
   （審査対応時の説明資料としても使える）。

---

## 3. 予備運用（案1）: 手動確認

GitHub Actions の実行が何らかの理由で失敗・遅延した場合に備え、以下を予備運用として行う。

- **1 日 1 回**、Firebase コンソールで `reports` / `blocks` コレクションを直接開き、
  `notified == false` のドキュメントが残っていないか目視確認する。
- 残っている場合は、上記「2. 通知受信時の対応手順」に従って対応する。
- ワークフローの実行状況は GitHub リポジトリの Actions タブ
  （`Moderation Notifier` ワークフロー）から確認できる。

---

## 4. 動作確認・トラブルシューティング

- **手動実行**: GitHub リポジトリの Actions タブ → `Moderation Notifier` →
  `Run workflow`（`workflow_dispatch`）で即時実行できる。
- **メールが届かない場合**:
  - Actions の実行ログでエラーが出ていないか確認する（SMTP認証エラー、
    Firebaseサービスアカウントの権限不足等）。
  - GitHub Secrets（`FIREBASE_SERVICE_ACCOUNT_JSON` / `SMTP_HOST` / `SMTP_PORT` /
    `SMTP_SECURE` / `SMTP_USER` / `SMTP_PASS` / `SMTP_FROM`）が正しく設定されているか確認する。
  - `notified == false` のドキュメントが実際に存在するか、Firebase コンソールで確認する
    （0 件の場合はメールが送信されない仕様）。
- **`notified` が更新されない場合**: Firebase サービスアカウントに Firestore への
  書き込み権限があるか確認する。

---

## 5. 将来の拡張

- 利用が増え Blaze プランへ移行した場合は、本スクリプトの定期実行を
  Firestore の `onCreate` トリガー（Cloud Functions）に置き換えることで、
  通知を即時化できる（`docs/review-fix-design.md` §7 参照）。その場合、本 GitHub Actions
  ワークフローは廃止してよい。
