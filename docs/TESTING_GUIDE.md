# Peephole 動作確認手順書

このドキュメントは、クラウド環境で実装した以下2つの機能をMac/Xcode上で実機・シミュレータ検証するための手順書です。

- 課題1: ウィジェットへの投稿画像表示（App Group経由のローカル画像方式）
- 課題2: ユーザー検索・フォローリクエストフロー

実装の設計背景は `docs/IMPLEMENTATION_PLAN.md` を参照してください。本書は「何を確認すればよいか」「ログが出ない時に何を疑うか」に特化しています。

---

## 0. 事前準備（必須・未実施）

コードには含まれない、Firebaseコンソール側の作業です。**これをやらないと課題2のE2Eテストが失敗します。**

### 0.1 複合インデックスの作成

Firebaseコンソール → Firestore Database → インデックス → 複合 で以下2件を作成（未作成の可能性が高いのは#2）。

| # | コレクション | フィールド構成 | 用途 |
|---|---|---|---|
| 1 | `posts` | `userId` ASC, `isExpired` ASC, `createdAt` DESC | タイムライン/ウィジェット取得 |
| 2 | `followRequests` | `targetId` ASC, `status` ASC, `createdAt` DESC | 通知画面の一覧取得 |

**確実な作成方法**: 該当画面（ホーム/通知）を実行し、Xcodeコンソールに出る `FAILED_PRECONDITION ... https://console.firebase.google.com/...` のURLをクリックすると、正しいフィールド構成で自動作成されます。インデックスが「有効」になるまで数分かかります。

### 0.2 セキュリティルールの公開

Firebaseコンソール → Firestore Database → ルール に `docs/IMPLEMENTATION_PLAN.md` の 3.8 節にあるルール全文を貼り付けて公開してください。

⚠️ **注意**: このルールはS2の修正（`checkFollowStatus`が自分基点のクエリになっていること）を前提に書かれています。本セッションでS2は実装済みなので、ルール公開前の追加修正は不要です。

### 0.3 既存テストデータの修正（該当する場合のみ）

Firestoreコンソール → `users` コレクションで、既存アカウントの `username` に大文字が含まれていれば手動で小文字に直してください（今回のusername小文字化より前に作成したアカウントが対象）。

---

## 1. ビルド確認

1. Xcodeでプロジェクトを開く
2. スキームを `Peephole` にして ⌘B → エラーが出ないこと
3. スキームを `PeepholeWidgetExtension` にして ⌘B → エラーが出ないこと
4. `Peephole/Shared/WidgetImageStore.swift` を選択 → File Inspector → Target Membership に **Peephole** と **PeepholeWidgetExtension** の両方にチェックが入っていること（pbxprojを直接編集したため、念のため目視確認を推奨）

もしウィジェット側のビルドが `Cannot find 'WidgetImageStore' in scope` のようなエラーで失敗する場合は、Target Membershipのチェックが外れている可能性が高いです。手動でチェックを入れてください。

---

## 2. 課題1: ウィジェット画像表示の確認

### 2.1 基本フロー

1. アプリを実行し、ログイン → ホーム画面が表示される
2. Xcodeコンソールで以下のログが順に出ることを確認:
   ```
   🔵 [WIDGET] Fetching following posts for widget...
   🔵 [WIDGET] publishWidgetData: 対象N件（除外前M件, excludingUserId=...)
   🔵 [IMAGE] ウィジェット用画像の準備を開始: 対象N件
   🔵 [IMAGE] 画像のダウンロードを開始: post(...), url: https://res.cloudinary.com/.../w_400,h_400,c_fill,q_auto,f_jpg/...
   🔵 [IMAGE] レスポンス受信: post(...), status: 200, サイズ: N bytes
   ✅ [IMAGE] 画像を保存しました: post(...) → post_xxx.jpg, サイズ: N bytes
   ✅ [IMAGE] ウィジェット用画像の準備が完了: N件
   ✅ Widget data saved successfully
   ✅ [IMAGE] クリーンアップ完了: N件の古い画像ファイルを削除しました
   ✅ [WIDGET] Widget timeline reloaded
   ✅ [WIDGET] Widget updated with following posts: N posts
   ```
3. ホーム画面に投稿がある状態で、ホーム画面ウィジェットを追加（または既存ウィジェットを長押し→編集で確認）→ **実際の投稿写真が表示される**こと

### 2.2 共有コンテナの中身を直接確認する

1. `SharedDataManager.swift` の `saveWidgetData` にブレークポイントを置くか、`imagesDirectoryURL` のログ出力（`✅ [IMAGE] WidgetImagesディレクトリを新規作成しました: <パス>`）からApp Group共有コンテナのパスを取得
2. Macのターミナルで:
   ```
   ls <コンテナパス>/WidgetImages/
   ```
   → `post_xxx.jpg` / `profile_xxx.jpg` が投稿数ぶん存在し、**1ファイルおおよそ30〜100KB程度**であること（400px JPEGなので大きすぎたら異常）
3. `cat <コンテナパス>/widgetData.json` → 各投稿の `localImageFileName` にファイル名が入っていること

### 2.3 3サイズ確認

1. スキームを `PeepholeWidgetExtension` に切り替えてRun → 実行先ダイアログでウィジェットサイズ（Small/Medium/Large）を選択
2. Small/Medium/Largeの3サイズすべてで写真が表示されること。Largeは投稿が4件未満でも落ちないこと
3. Xcodeコンソール（ウィジェットプロセス）に以下が出ること:
   ```
   ✅ [IMAGE] 画像を読み込みました: post_xxx.jpg, size: (400.0, 400.0)
   ```
   出ない場合、あるいは `⚠️ [IMAGE] 画像読み込み: ファイルが存在しません` が出る場合は 2.2 の手順でファイルの有無を確認

### 2.4 キャッシュ・オフライン確認

1. 同じ投稿でホームを再読み込み（Pull to Refresh）→ コンソールに `🔵 [IMAGE] キャッシュヒット、ダウンロードをスキップ: post_xxx.jpg` が出ること（再ダウンロードしていない）
2. 機内モードにして本体アプリを一度も開かずウィジェットを追加し直しても、保存済み画像が表示されること

### 2.5 新規投稿・自分の投稿の除外確認（F1）

1. 投稿を新規作成 → 数秒後ウィジェットに新しい写真が出る
2. フォロー0人の新規アカウントでログイン → ウィジェットが「投稿がありません」になること（自分の投稿はホームには出るが、ウィジェットには出ない）
3. 相互フォロー後は友達の投稿のみがウィジェットに出て、自分の投稿は出ないこと

### 2.6 未ログイン・初回起動時の確認（W7）

1. シミュレータのアプリを削除→再インストール
2. ログイン前にウィジェットを追加 → モックではなく「投稿がありません」（`EmptyWidgetView`）が表示される
3. ログイン後にアプリを開いてから戻ると実データが表示される

### 2.7 メモリ確認

Xcode の Debug Navigator でウィジェットプロセスのメモリが数MB台であること（30MB制限に対して余裕があること）

---

## 3. 課題2: ユーザー検索・フォローのE2E確認

準備: 0.1（インデックス有効）・0.2（ルール公開済み）が終わっていること。シミュレータ2台（例: iPhone 16 / iPhone 16 Pro）にそれぞれアカウントA/Bでログイン。

| # | 操作 | 期待結果 |
|---|---|---|
| 1 | A: サインアップ（例 `usera`）、写真付きで1件投稿 | `users/{A}` 作成、`posts` に1件 |
| 2 | B: サインアップ（例 `userb`） | `users/{B}` 作成 |
| 3 | B: 発見タブで `use` と入力 | 0.4秒後、Aのみ表示（自分は除外） |
| 4 | B: Aをタップ → プロフィール | 「フォローする」（青）。投稿グリッドは「フォローすると表示されます」 |
| 5 | B: フォローする | 「リクエスト中」（灰）に変化。`followRequests` に pending 1件 |
| 6 | B: もう一度タップ → 確認ダイアログ「取り消す」 | 「フォローする」に戻る。`followRequests` 空。**再度リクエスト送信して次へ** |
| 7 | A: 通知タブ | バッジ「1」、`@userb` の行に承認/拒否ボタン |
| 8 | A: 拒否（確認ダイアログ経由） | 行が消える・バッジ0。`followRequests` 空。**B側から再度リクエスト** |
| 9 | A: 承認（確認ダイアログ経由） | 行が消える・**バッジが即0になる**。`follows` に1件、両者のカウンタ更新 |
| 10 | B: ホームをPull-to-Refresh | Aの投稿がタイムラインに出る |
| 11 | B: バックグラウンド→フォアグラウンド → ホーム画面のウィジェット | **Aの投稿が写真付きで表示される（課題1×課題2の統合確認）** |
| 12 | B: Aのプロフィール →「フォロー中」タップでフォロー解除 | カウンタが両者とも0に戻る。リフレッシュ後タイムラインからAの投稿が消える |

### 3.1 検索まわりの確認ポイント

- `@` 付き・大文字で入力してもヒットする（例: `@UserA` でもヒット）
- 高速に文字を打っても検索が連発しないこと（コンソールの `🔵 [DISCOVER] ユーザー検索を開始` の頻度で確認。0.4秒デバウンスされているはず）

---

## 4. ログ期待値 対応表

### 4.1 ウィジェット画像パイプライン

| 期待されるログ | 出るタイミング | 出ない/エラーが出た場合に疑う箇所 |
|---|---|---|
| `🔵 [WIDGET] Fetching following posts for widget...` | アプリ起動・フォアグラウンド復帰時 | `RootView.updateWidgetIfNeeded()` が呼ばれていない → `authViewModel.currentUserId` がnil（未ログイン） |
| `🔵 [WIDGET] publishWidgetData: 対象N件...` | 投稿取得後 | Firestoreクエリの失敗（下記の `❌ [WIDGET] Failed to update widget...`） |
| `🔵 [IMAGE] 画像のダウンロードを開始: ...` | 画像未キャッシュ時 | 出ずに即 `✅` が出る場合はキャッシュヒット（正常）。投稿数分のログが出ない場合は `FirestorePost.imageURL` が空/不正 |
| `❌ [IMAGE] 画像のダウンロードに失敗（HTTPエラー）` | Cloudinary側エラー | URLのtransformationsが不正 or Cloudinary側の画像が削除済み |
| `❌ [IMAGE] 画像のダウンロードに失敗（デコード不可）` | レスポンスがJPEGでない | `generateWidgetImageURL` が `f_jpg` を付与できていない（Cloudinary以外のURL、`/upload/` が無いURL） |
| `✅ [IMAGE] 画像を保存しました: ... → post_xxx.jpg` | 保存成功時 | 出ない場合は `WidgetImageStore.save` が失敗 → 下記参照 |
| `❌ [IMAGE] WidgetImagesディレクトリの作成に失敗しました` | App Group設定不備 | Xcode → Signing & Capabilities → App Groups が両ターゲットで `group.app.takaoka.com.peephole.shared` になっているか確認 |
| `✅ Widget data saved successfully` | JSON保存成功 | 出ない場合はApp Groupの共有コンテナ自体が取得できていない（上記と同じ原因） |
| `✅ [IMAGE] クリーンアップ完了: N件の古い画像ファイルを削除しました` | JSON保存直後 | 出ない場合は`publishWidgetData`が最後まで到達していない（前段のクラッシュ/例外） |
| `✅ [WIDGET] Widget timeline reloaded` | 最後 | 出ているのにウィジェットの見た目が変わらない場合はOSのreloadスロットリング。ウィジェットを長押し→削除→再追加で解消することが多い |
| （ウィジェットプロセス側）`✅ [IMAGE] 画像を読み込みました: post_xxx.jpg` | ウィジェット描画時 | 出ずに `⚠️ [IMAGE] 画像読み込み: ファイルが存在しません` → JSONとファイルの不整合（`localImageFileName`はあるがファイルが無い＝pathの不一致 or cleanupが先に走った） |
| （ウィジェットプロセス側）`❌ [IMAGE] 画像読み込み: UIImageの生成に失敗しました` | ファイルは存在するが壊れている | 保存時のデータが不正（ネットワークが途中で切れた等）。次回の更新で上書きされるか確認 |

### 4.2 ユーザー検索・フォロー

| 期待されるログ | 出るタイミング | 出ない/エラーが出た場合に疑う箇所 |
|---|---|---|
| `🔵 [USER] searchUsers: クエリ="..."` | 発見タブで文字入力（0.4秒後） | 出ない場合は `.task(id:)` のデバウンスが発火していない、または `authViewModel.currentUserId` がnil |
| `✅ [USER] searchUsers: N件取得` | 検索成功 | `0件` が続く場合は0.3節の既存データ未修正（大文字混じりusername）を疑う |
| `❌ [USER] searchUsers失敗` | Firestoreエラー | `permission denied` ならルール未公開(0.2)、`FAILED_PRECONDITION` ならインデックス未作成(0.1) |
| `🔵 [FOLLOW] フォローリクエスト送信を開始: A → B` | フォローボタンタップ時 | 出ない場合はボタンのアクションが `sendFollowRequest` に到達していない |
| `✅ [FOLLOW] フォローリクエスト送信成功` | 送信成功 | `permission denied` エラーの場合はルール未公開、または`requesterId`が`request.auth.uid`と不一致 |
| `🔵 [FOLLOW] hasPendingRequest: A → B = true/false` | プロフィール画面表示時 | 常に`false`でボタンが「フォローする」のままの場合、リクエストがそもそも保存されていない可能性（Firestoreコンソールで`followRequests`を直接確認） |
| `🔵 [FOLLOW] フォローリクエスト承認を開始` → `✅ [FOLLOW] フォローリクエスト承認成功` | 通知画面で承認 | 失敗時は `transactionFailed` エラー内容を確認。カウンタ更新の権限エラーなら0.2のルールの`affectedKeys().hasOnly`条件を再確認 |
| `🔵 [FOLLOW] getPendingFollowRequests: targetId=..., status=pending` | 通知画面読み込み時 | `✅` の件数が実際のリクエスト数と合わない場合はインデックス未構築（構築中はエラーになるはずなので、エラーメッセージも合わせて確認） |

---

## 5. トラブル時の切り分け早見表

| 症状 | 最初に見るべきログ | 次に確認する場所 |
|---|---|---|
| ウィジェットが常に灰色/「投稿がありません」 | `⚠️ [WIDGET] widgetData.jsonが無い、または投稿が空` | `❌ [WIDGET] Failed to update widget...` の有無、Firestore側のフォロー関係 |
| ウィジェットは出るが画像だけ表示されない | ウィジェットプロセスの `⚠️/❌ [IMAGE]` ログ | 2.2節の手順で共有コンテナのファイル有無を直接確認 |
| 発見タブで誰も見つからない | `✅ [USER] searchUsers: N件取得` の件数 | 0.3節（既存データのusername大文字混じり） |
| 通知画面が「読み込みに失敗しました」 | `❌ [FOLLOW] ...` のエラー内容 | 0.1節（`followRequests`複合インデックス） |
| フォロー操作が軒並み `permission denied` | エラーメッセージの詳細 | 0.2節（ルール未公開）、S2の修正が反映されているか |
| ビルドが通らない（ウィジェット側） | Xcodeのビルドエラーメッセージ | 1章のTarget Membership確認 |
