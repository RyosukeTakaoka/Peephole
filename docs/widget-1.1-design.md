# 1.1 ウィジェット改善 設計ドキュメント（投稿ローテーション / サイレントプッシュ更新）

- 作成日: 2026-07-20
- 前提ドキュメント: `docs/review-fix-design.md`（審査リジェクト対応。T1〜T23。以下「審査対応設計書」）
- 対象: 1.1 機能としてのウィジェット改善 2 件
  - 機能1: 投稿ローテーション（時計駆動・更新予算を消費しない）
  - 機能2: イベント駆動更新（サイレントプッシュ）
- 本ドキュメントは**設計のみ**を記述する。実装コードは含まない。

---

## 0. 要約（結論）

| 項目 | 結論 |
|---|---|
| 機能1 の実現可能性 | **実現可能。かつ骨格は実装済み**。現行ウィジェットは既に「30 分間隔 × 48 エントリ（24 時間分）を一括予約」するローテーションタイムラインを持つ（`PeepholeWidget.swift` の `getTimeline`）。1.1 での作業は「15 分化＋既存課題の修正」であり、変更は実質 1 ファイル・規模は小 |
| 機能2 の実現可能性 | 実現可能。ただし **「投稿した瞬間に必ず反映」は iOS の仕様上保証できない**（サイレントプッシュのスロットリング＋ウィジェット更新予算の二重制限）。実態は「数分以内〜条件次第で数十分」のベストエフォート |
| プッシュ経由の reload は予算を食うか | **食う**。予算免除はアプリがフォアグラウンドのときのみ。バックグラウンド起床（サイレントプッシュ）からの `reloadTimelines` は日次予算 40〜70 回を消費する。クライアント側スロットル（§4.6）が必須 |
| Blaze | 機能2 は **Blaze 承認が前提**（Cloud Functions のデプロイに必須）。これは審査対応設計書 §9.1 #1 の「Blaze は承認しない」決定の変更を意味する（要確認事項 #15）。想定規模での月額は §5.2 の通り 100 MAU で実質 ¥0、1,000 MAU で 〜¥1,000 程度 |
| リリース戦略 | **機能1 だけを 1.1 として先行リリースすることを強く推奨**（§5.5）。機能2 は Blaze 承認・APNs 手作業・実機検証・Functions 運用整備が揃ってから 1.2 として出す |
| 審査への影響 | 機能1: なし（WidgetKit 標準機構のみ）。機能2: リスク低。サイレントプッシュ専用なら**通知許可プロンプト自体が不要**で、Background Modes（remote-notification）はウィジェット鮮度維持という正当用途（Guideline 2.5.4 適合）。詳細 §6 |

---

## 1. 現状確認（実装調査結果）

### 1.1 ウィジェット更新経路の現状

```
[更新トリガー]
  アプリ起動 / フォアグラウンド復帰 (RootView.onChange(scenePhase))
  投稿作成 (PostCreateViewModel)
  ブロック/通報 (HomeViewModel)
        │
        ▼
WidgetDataUpdater.updateWidgetWithFollowingPosts(userId:)
  ├─ follows / blocks / hiddenPosts を読み取り対象ユーザーを決定
  ├─ getTimelinePosts(userIds:, limit: 6)   ← 最大6件は実装済み
  ├─ サムネ/プロフィール画像を事前DL → App Group widgetImages/（T21 実装済み）
  ├─ widgetData.json 保存
  └─ WidgetCenter.reloadAllTimelines()      ← フォアグラウンド実行なので予算免除
        │
        ▼
PeepholeWidgetProvider.getTimeline
  └─ 30分間隔 × 48 エントリ（24時間分）を一括予約、policy: .after(最終エントリ)
     各エントリは displayIndex = index % posts.count で表示位置を回す
```

### 1.2 既に実装済みの事項（機能1 の前提が揃っている）

- **時計駆動ローテーション本体**: `getTimeline` が未来 24 時間分のエントリを一括予約している。エントリの表示切替は WidgetKit がスケジュールに従って行うだけで**更新予算を消費しない**。ユーザー要件の「未来分のエントリをまとめて予約する方式」は現行コードそのもの。
- **最大 6 件**: `WidgetDataUpdater` が `limit: 6` で取得済み。
- **画像のローカル配信（T21）**: 全 6 件分のサムネ・プロフィール画像が App Group に保存済みのため、**どのエントリに切り替わってもネットワーク不要で描画できる**。ローテーションと相性が良い（エントリごとの追加ダウンロードは発生しない）。
- **サイズ別の表示件数**: Small=1 / Medium=2 / Large=4 件を `displayIndex` からのオフセットで表示（`postsToDisplay(for:)`）。

### 1.3 未整備の事項（機能2 はゼロからの積み上げ）

| 項目 | 現状 |
|---|---|
| Push Notifications capability | なし（`Peephole.entitlements` は App Groups のみ。`aps-environment` なし） |
| Background Modes | なし（Info.plist に `UIBackgroundModes` キーなし） |
| FCM | `FirebaseMessaging` は SPM でリンク済みだが、Info.plist で `FirebaseMessagingAutoInitEnabled=false` / `FirebaseAppDelegateProxyEnabled=false` により**明示的に無効化**。トークン取得・保存コードなし |
| APNs キー | Firebase Console 未設定（手作業項目。§5.4） |
| サーバ側 | Cloud Functions なし（Blaze 非承認決定のため）。`FirebaseFunctions` の SPM リンクのみ存在 |
| AppDelegate | `PeepholeApp.swift` に `UIApplicationDelegateAdaptor` で存在。`didReceiveRemoteNotification` の追加は素直にできる |

### 1.4 調査で見つけた既存の課題（機能1 と同時に修正すべき）

1. **空状態が 30 分ポーリングになっている**: 投稿 0 件のとき `policy: .after(30分)` の単一エントリを返すため、**空のウィジェットが 30 分ごとにバックグラウンドリロードを要求し続ける**（≒ 48 回/日 で予算を浪費）。空状態のデータはアプリ起動時に必ず再構築されるので、システム再読込に頼る必要はない。→ T24 で `.after(4〜6時間)` 程度に緩和する。
2. **リロードのたびにローテーション位相がリセットされる**: エントリ日付が `現在時刻 + n×30分` で生成されるため、アプリをフォアグラウンドに出すたびに `displayIndex=0`（最新投稿）から再スタートする。頻繁にアプリを開くユーザーには 1 枚目ばかり表示される。→ T24 で壁時計アラインに変更（§3.3）。
3. **posts が 1 件のときも 48 エントリ生成**: 全エントリ同一表示になり無駄。→ 単一エントリに縮退。

---

## 2. WidgetKit 更新予算の整理（両機能共通の前提）

設計判断の根拠として、予算の実態を整理する。

| 操作 | 予算消費 |
|---|---|
| タイムラインエントリの表示切替（予約済みエントリを時刻どおり表示） | **消費しない**（機能1 の根拠） |
| `TimelineReloadPolicy`（`.after` 等）によるシステム再読込 | 消費する（1 回分） |
| アプリが**フォアグラウンド**のときの `WidgetCenter.reloadTimelines` | **消費しない**（免除。現行の全リロード経路はこれ） |
| アプリが**バックグラウンド**のときの `reloadTimelines`（サイレントプッシュ起床を含む） | **消費する**（機能2 の制約の根拠） |

- 予算量: よく表示されるウィジェットでおおむね **40〜70 リロード/日**（15〜60 分に 1 回相当）。予算超過分のリロード要求は破棄されず**次の予算枠まで遅延**される。
- したがってユーザーの質問「プッシュ経由の reload も予算を食うのか」への回答は**「食う」**。機能2 は「サイレントプッシュ配信そのもののスロットリング（§4.6）」と「reload 予算」の**二重の制限**下で動く。

---

## 3. 機能1: 投稿ローテーション（時計駆動）設計

### 3.1 方針

現行の 30 分ローテーションを 15 分化し、§1.4 の既存課題を同時に修正する。**エントリ数は実績のある 48 のまま維持**し、カバー範囲を 24 時間 → 12 時間に変える（15 分 × 48 = 12 時間）。

- 96 エントリ（15 分 × 24 時間）の一括予約も技術的には可能だが、WidgetKit はエントリのビューをアーカイブとして事前レンダリングするため、エントリ数を倍にするとレンダリング負荷・アーカイブサイズが倍になる（Large は 1 エントリ 4 画像）。48 エントリは T21 の実機検証で動作実績があるため、**48 を維持して `.after` 継ぎ足しにする方が安全**。
- 12 時間後の `.after` によるシステム再読込は 2 回/日で予算（40〜70/日）の誤差。かつ `getTimeline` はローカル JSON を読むだけ（ネットワークなし）なので実行コストも極小。アプリが 12 時間以上開かれなくても、保存済みデータでローテーションが継ぎ足される（データは古くなるが回り続ける）。

### 3.2 変更ファイル

| ファイル | 種別 | 変更内容 |
|---|---|---|
| `PeepholeWidget/PeepholeWidget.swift` | 変更 | `getTimeline` のみ変更（§3.3）。`rotationInterval` を 15 分に、エントリ日付を壁時計アライン、空状態ポリシー緩和、1 件時の縮退。ビュー・`postsToDisplay` は無変更 |

**変更はこの 1 ファイルのみ**。`WidgetDataUpdater` / `SharedDataManager` / `Models` / 各 WidgetView は無変更。アプリターゲットも無変更。

### 3.3 エントリ生成仕様（新）

```
入力: widgetData.json の posts（最大6件、createdAt 降順）

1. posts が空     → 単一エントリ（空状態）+ policy .after(4時間)
2. posts が1件    → 単一エントリ（displayIndex 0）+ policy .after(12時間)
3. posts が2件以上:
   - slot(t) = floor(t / 900秒)                    // 15分スロット番号（絶対時刻由来）
   - 先頭エントリ: date = 現在時刻, displayIndex = slot(現在時刻) % posts.count
   - 以降47エントリ: date = 次の15分境界から15分刻み,
                     displayIndex = slot(date) % posts.count
   - policy: .after(最終エントリ date)
```

- **壁時計アライン**: `displayIndex` を絶対時刻のスロット番号から導出することで、リロードがいつ何回起きても「その時刻に表示されるべき投稿」が一意に決まる（§1.4-2 の位相リセット解消）。切替は毎時 :00/:15/:30/:45 に揃う。
- 新着投稿時はアプリ側の既存経路（投稿作成→フォアグラウンド reload）でデータが差し替わり、`posts[0]` が最新になるため、スロットが `% posts.count` で回る中で自然に新着も表示に入る。「新着を必ず即先頭表示」したい場合は先頭エントリのみ `displayIndex=0` に固定する変種もあるが、位相アラインの利点（表示の決定論性）を損なうため採用しない。
- 表示切替の時刻精度: エントリ切替は予算外だが、システム状態（Low Power Mode、StandBy 等）により分単位の遅延はあり得る。15 分粒度は写真系ウィジェットで一般的であり問題ない。**30 秒級の時計駆動が不可能である事情とは独立**（あちらはエントリ密度が桁違いでシステムが尊重しない）。

### 3.4 エッジケース

| ケース | 挙動 |
|---|---|
| 投稿 0 件 | EmptyWidgetView 単一エントリ。`.after(4時間)`（§1.4-1 の修正） |
| 投稿 1 件 | 単一エントリで固定表示。ローテーションなし |
| 画像 DL 失敗（`localImageFileName == nil`） | 従来どおりプレースホルダ表示。次回のフォアグラウンド更新でリトライ（T21 の失敗モードのまま） |
| Medium/Large で件数 > posts.count | 既存の `% posts.count` 折り返しで重複表示（現行挙動維持） |
| DEBUG モックデータ | 6 件固定なのでそのままローテーション確認に使える |

### 3.5 実現可能性評価と規模

- **実現可能性: 確実**。現行実装の実績ある機構のパラメータ変更＋位相計算の差し替えであり、新規のシステム連携はない。
- **実装規模: 小**（`getTimeline` の書き換えのみ、差分 50 行未満。1 コミット）。
- **依存関係: なし**。Blaze・Firebase・手作業・ルール変更すべて不要。審査上の新規要素もなし。
- 検証項目: ①実機で 15 分境界の切替を確認、②Large（4 画像 × 48 エントリ）でエントリ欠落（アーカイブ切り詰め）が起きないこと、③空状態でバックグラウンドリロードが 4 時間間隔になること（Console ログ）。

---

## 4. 機能2: イベント駆動更新（サイレントプッシュ）設計

### 4.1 アーキテクチャ

```
投稿作成（クライアント）
  └→ Firestore posts/{postId} 作成
       └→ [Cloud Functions v2] onPostCreated（Firestore onDocumentCreated トリガー）
            ├─ follows（followingId == 投稿者）からフォロワー ID を取得
            ├─ 各フォロワーの FCM トークンを取得（§4.2）
            ├─ FCM Admin SDK でサイレントプッシュを一斉送信（§4.5）
            └─ 無効トークン（unregistered）を削除
                 │ APNs（ベストエフォート・スロットリングあり §4.6）
                 ▼
フォロワーの端末: アプリがバックグラウンド起床（最大約30秒）
  └→ AppDelegate.didReceiveRemoteNotification
       ├─ スロットル判定（前回 reload から15分未満なら保存のみ／reload 抑制 §4.6）
       ├─ WidgetDataUpdater.updateWidgetWithFollowingPosts（既存メソッド再利用）
       │    └─ データ取得・画像DL・widgetData.json 保存・reloadAllTimelines
       └─ completionHandler(.newData / .failed)
```

- クライアントの更新処理は**既存の `updateWidgetWithFollowingPosts` をそのまま再利用**する（フル再取得）。ブロック・通報非表示の反映も既存ロジックで担保される。
- 最適化オプション（初期実装では見送り可）: ペイロードの `postId` で当該投稿 1 件のみ取得して `widgetData.json` にマージすれば、起床あたりの Firestore 読み取りを約 20 → 2 件に減らせる。ブロック/非表示の判定が「前回フル更新時のローカル知識」頼みになるトレードオフがあるため、コストが問題化してから導入する（§5.2 の試算はフル再取得前提）。

### 4.2 データモデル: FCM トークンの保存

**採用: `users/{userId}/private/push` ドキュメント方式**

```
users/{userId}/private/push
  fcmToken: String
  updatedAt: Timestamp
  platform: String        // "ios"（将来用）
```

```
// firestore.rules 追記（users の match 内）
match /private/{docId} {
  allow read, write: if signedIn() && request.auth.uid == userId;
}
```

- 却下案A（`users/{uid}` に `fcmToken` フィールド直置き）: ルール変更不要で最小だが、現行ルールは users の read が全認証ユーザーに開いているため（審査対応設計書 §6.1 の既知の割り切り）、全ユーザーのトークンが読める状態になる。トークン単独でプッシュ送信はできない（サーバ側サービスアカウントが必要）ものの、email に加えて公開面を広げる必要はない。
- 却下案B（`fcmTokens/{token}` サブコレクションで複数端末対応）: 本アプリは 1 ユーザー 1 端末想定で過剰。単一ドキュメント上書きなら古いトークンの掃除も不要になる。複数端末要件が出たら移行（要確認事項 #17）。
- Cloud Functions は Admin SDK（ルール対象外）で読むため、クライアント読み取りは本人のみで問題ない。
- トークン更新タイミング: 起動時（`didRegisterForRemoteNotificationsWithDeviceToken` → FCM トークン取得後）と `messaging(_:didReceiveRegistrationToken:)` デリゲートで upsert。ログアウト・アカウント削除時は `Messaging.deleteToken` ＋ ドキュメント削除（アカウント削除は既存 `deleteUserData` のカスケードに 1 手順追加）。

### 4.3 Cloud Functions 設計

| 成果物 | 内容 |
|---|---|
| `functions/`（新規、Node.js 20 / firebase-functions v2） | `onPostCreated`: `onDocumentCreated("posts/{postId}")`。①`isHidden == true` なら何もしない ②follows から followerIds 取得（投稿者自身は含めない）③各 `users/{id}/private/push` からトークン収集 ④`sendEachForMulticast` でサイレントプッシュ送信 ⑤`messaging/registration-token-not-registered` エラーのトークンドキュメントを削除 |
| `firebase.json` / `.firebaserc` | functions デプロイ設定（リポジトリに追加） |

- リージョンは Firestore ロケーションに合わせる（`asia-northeast1` 想定。単価に影響）。
- 送信スキップ条件: フォロワー 0 人・トークン 0 件は即 return（コスト最小化）。
- ブロック関係の除外: follows はブロック時に削除される設計（T6）のため、フォロワー一覧に基づく送信で自然に除外される。追加チェック不要。
- サーバ側スロットルは初期実装では持たない（受信者ごとの lastPushAt 管理は読み書きコストが増える割に、iOS 側のスロットリング＋クライアント側スロットルで実効的に律速されるため）。
- 失敗時挙動: Functions が失敗してもプッシュが飛ばないだけで、既存のフォアグラウンド更新経路が生きているため機能劣化は「即時性の喪失」に留まる（データ破壊なし）。リトライ設定は不要（イベントは冪等でないが、二重送信の実害は余分な reload 1 回のみ）。

### 4.4 iOS クライアント設計

| ファイル | 種別 | 変更内容 |
|---|---|---|
| `Peephole/Peephole.entitlements` | 変更 | `aps-environment`（Xcode の Push Notifications capability 追加で自動付与） |
| `Peephole/Info.plist` | 変更 | `UIBackgroundModes: [remote-notification]` 追加。`FirebaseMessagingAutoInitEnabled` は `true` に変更（または削除） |
| `Peephole/PeepholeApp.swift`（AppDelegate） | 変更 | ①`didFinishLaunching` で `Messaging.messaging().delegate = self` と `application.registerForRemoteNotifications()`（**許可プロンプトは出ない** §6）②`didRegisterForRemoteNotificationsWithDeviceToken` で `Messaging.messaging().apnsToken = deviceToken`（**`FirebaseAppDelegateProxyEnabled=false` のため手動連携が必須**。忘れると FCM トークンが APNs に紐付かず配信されない — 本設計最大の実装落とし穴）③`didReceiveRemoteNotification:fetchCompletionHandler` でペイロード判定 → 更新実行 → completionHandler |
| `Peephole/Services/PushService.swift` | 新規 | 既存規約どおりシングルトン。トークンの取得・`users/{uid}/private/push` への upsert・削除。`MessagingDelegate` の受け口 |
| `Peephole/Shared/SharedDataManager.swift` | 変更 | `lastPushReloadAt` の読み書き（App Group UserDefaults）。スロットル判定用 |
| `Peephole/Services/UserService.swift` | 変更 | `deleteUserData` のカスケードに `private/push` 削除を追加 |
| `Peephole/ViewModels/AuthViewModel.swift` | 変更 | ログイン後にトークン登録、ログアウト時に `PushService` のトークン削除を呼ぶ |
| `firestore.rules` | 変更 | §4.2 の `private` サブコレクションルール追加 |

- バックグラウンド起床中の実行時間は約 30 秒。`updateWidgetWithFollowingPosts` は数十 KB の画像 6 枚以内の DL であり通常収まるが、タイムアウト時はシステムに打ち切られる（次回フォアグラウンドで回復するため実害なし）。
- 認証状態: 起床時に FirebaseAuth のセッションが復元されていることが前提（Keychain 由来で通常は成立）。未認証なら何もせず `.noData` で終える。

### 4.5 ペイロード設計

FCM Admin SDK（HTTP v1）からの送信メッセージ:

```json
{
  "token": "<受信者のFCMトークン>",
  "data": { "type": "new_post", "postId": "<作成された投稿ID>" },
  "apns": {
    "headers": {
      "apns-priority": "5",
      "apns-push-type": "background"
    },
    "payload": { "aps": { "content-available": 1 } }
  }
}
```

- `content-available: 1` のみ（alert / sound / badge なし）= サイレントプッシュ。
- `apns-priority` は **5 必須**（10 を指定するとサイレントプッシュとして不正で配信されない）。`apns-push-type: background` は iOS 13+ で必須。FCM の `apns.headers` で明示する。
- `data.postId` は現状未使用（フル再取得のため）だが、§4.1 の増分更新オプションとログ調査のために最初から積んでおく。
- `type` フィールドで将来の可視通知（フォローリクエスト等）とハンドラを分岐できるようにする。

### 4.6 配信制約と更新予算への影響（期待値の明文化）

**サイレントプッシュは以下の多段の制限を受ける。「投稿の瞬間に必ず反映」は設計目標にできない。**

| 制限 | 内容 | 本設計への影響 |
|---|---|---|
| APNs/iOS のスロットリング | サイレントプッシュはシステムが低優先度扱いし、**1 アプリあたり毎時 2〜3 通程度**を超えると配信が間引き・遅延される。端末の電力状態・アプリの利用頻度で変動 | フォロー 20 人 × 各 3 投稿/日 = 受信者あたり 60 通/日 ≒ 2.5 通/時 で、**普通の利用規模ですでに閾値に達する**。閾値内でも配信は数分遅延し得る |
| ウィジェット更新予算 | バックグラウンド reload は 40〜70 回/日 を消費（§2） | プッシュ全通で reload すると予算とほぼ同オーダー。**クライアント側スロットル（下記）が必須** |
| Background App Refresh オフ | 設定でオフのユーザーにはサイレントプッシュが配信されない | 対策なし（フォアグラウンド更新で回復） |
| 強制終了（スワイプキル） | force-quit されたアプリはサイレントプッシュで起床されない | 同上 |
| Low Power Mode | 配信が停止・遅延 | 同上 |

**クライアント側スロットル（採用）**: `didReceiveRemoteNotification` で App Group の `lastPushReloadAt` を確認し、**前回のプッシュ起因 reload から 15 分未満なら何もせず `.noData` で終える**（データ取得もスキップし、読み取りコストと実行時間も節約）。15 分はローテーション間隔（機能1）と揃えており、「ウィジェットの実効鮮度は最良で即時、最悪でも約 15 分」という一貫した鮮度モデルになる。フォアグラウンド経路の reload はスロットル対象外（従来どおり即時・予算免除）。

**結果としての体験**: 投稿がまばらな時間帯（本アプリの想定利用の大半）はほぼ即時に反映される。投稿が連続する時間帯は 15 分粒度に丸められる。これはウィジェット予算の設計思想とも整合し、審査上も説明しやすい。

### 4.7 実装規模と依存関係

- **実装規模: 中**。iOS 側 新規 1 ファイル＋変更 6 ファイル、`functions/` 一式新規、ルール追記。コード自体は 2〜3 コミット規模だが、**Blaze 移行・APNs 鍵・実機検証・Functions デプロイ運用**という非コード作業が全体工数の半分を占める。
- **依存関係**: ①Blaze 承認（ゲート。要確認事項 #15）②APNs 手作業（§5.4）③機能1 とはコード上独立（どちらが先でも良いが、§5.5 の理由で機能1 先行を推奨）。
- **検証は実機必須**（シミュレータの APNs は挙動が不完全）。TestFlight ビルドは production APNs 環境を使うため、開発ビルドと両環境での確認が要る。

---

## 5. 評価事項への回答

### 5.1 実装規模と依存関係の比較

| | 機能1（ローテーション15分化） | 機能2（サイレントプッシュ） |
|---|---|---|
| 変更範囲 | `PeepholeWidget.swift` のみ（差分 <50 行） | iOS 7 ファイル＋`functions/` 新規＋rules＋entitlements/plist |
| 新規インフラ | なし | Cloud Functions / FCM / APNs |
| 手作業 | なし | APNs キー・Firebase 設定・Blaze 移行・実機検証（§5.4） |
| 課金 | なし | Blaze 前提（§5.2） |
| 審査リスク | なし | 低（§6） |
| 失敗時の劣化 | 現状維持 | 即時性を失うだけ（既存経路で回復） |
| 目安工数 | 半日（検証込み1日） | コード 2〜3 日＋セットアップ/検証 1〜2 日 |

### 5.2 Blaze 承認が必要な範囲と月額試算

**Blaze が必要になる範囲**: Cloud Functions のデプロイのみ（FCM 送信自体は無料で、Blaze も不要）。Functions v2 は Cloud Run ベースのため、初回デプロイ時に Cloud Build / Artifact Registry / Cloud Run の各 API 有効化を伴う（firebase CLI が誘導）。**逆に言えば、機能1・既存機能・T17（GitHub Actions 通知）は引き続き Blaze 不要**。

**参考（不採用）**: Blaze なしの近似案として「GitHub Actions の定期実行（T17 と同基盤）で新規投稿を検出しサービスアカウントから FCM 送信」は技術的に可能だが、最短でも 30 分間隔のポーリングとなり「イベント駆動」の意味を失う（機能1 の 15 分ローテーションに劣る）。機能2 をやるなら Blaze 一択。

**月額試算**（審査対応設計書 §7.3 の前提を踏襲: DAU=MAU×30%、フォロー平均 20 人、投稿 3 件/日/DAU、$1=¥150。プッシュ起床はフル再取得 ≒20 reads/回、iOS スロットリングにより受信者あたり実効 ~50 通/日 上限、クライアントスロットルで reload ≤ 4 回/時）:

| 規模 | Functions 呼出/月 | FCM 送信/月 | 追加 Firestore 読取/日 | 機能2 追加分の月額 | 既存分（§7.3）込み合計 |
|---|---|---|---|---|---|
| 100 MAU（30 DAU） | 約 2,700（無料枠 200 万の誤差） | 約 5.4 万（無料） | 約 2〜3 万 | **¥0〜100** | ¥0〜100 |
| 1,000 MAU（300 DAU） | 約 2.7 万 | 約 54 万（無料） | 約 20〜30 万 | **約 ¥500〜800** | 約 ¥500〜900 |
| 10,000 MAU（3,000 DAU） | 約 27 万 | 約 540 万（無料） | 約 200〜300 万 | **約 ¥5,000〜8,000** | 約 ¥6,000〜9,500 |

- 支配項は Functions でも FCM でもなく、**プッシュ起床時のクライアント Firestore 読み取り**（フル再取得のため 1 起床 ≒ 20 reads）。1,000 MAU を超えて費用が気になり始めたら §4.1 の増分更新（1 起床 ≒ 2 reads、費用約 1/10）に切り替える。
- 付随費用: Artifact Registry（関数イメージ保管）が月数円〜数十円。リージョン `asia-northeast1` は米国比で単価 +2〜3 割（表は概算に織込み済み）。
- ガードレール: 審査対応設計書 §7.4 のとおり予算アラート ¥500/¥1,000/¥3,000 を設定。本設計の Functions は Firestore 書き込みを（トークン削除以外）行わないため、**自己トリガーの無限ループ構造を持たない**（暴走課金の典型パターンを構造的に回避）。

### 5.3 サイレントプッシュと iOS 予算制限の相互作用（質問への直接回答)

1. **プッシュ経由の reload は更新予算を消費する**。免除はフォアグラウンドのみ。
2. さらに手前で、**サイレントプッシュの配信自体が毎時 2〜3 通程度にスロットリングされる**。つまり「Functions が送った数」＝「端末が起きる数」ではない。
3. 二つの制限は同オーダー（配信 ~50/日 vs 予算 40〜70/日）のため、無制御だとプッシュだけで予算を使い切り、フォアグラウンド以外の更新が丸ごと遅延し始める。→ クライアント側 15 分スロットル（§4.6）で reload を最大 ~96 回/日 → 実効的にはるかに少ない回数に抑え、予算内に収める。
4. 結論: サイレントプッシュは「毎投稿を確実に即反映する仕組み」ではなく、**「フォアグラウンド更新の合間を埋める、最良ケース即時・最悪 15 分粒度のベストエフォート鮮度向上」**として設計する。この期待値なら iOS の制限と衝突しない。

### 5.4 APNs まわりで必要な手作業（チェックリスト）

コードで自動化できない、アカウント権限が必要な作業。すべて機能2 のみに必要:

1. **APNs 認証キー（.p8）の作成** — Apple Developer → Certificates, Identifiers & Profiles → Keys → 「Apple Push Notifications service (APNs)」で作成。**ダウンロードは 1 回限り**なので安全に保管し、Key ID と Team ID を控える。証明書（.p12）方式は年次更新が必要なため使わない（キーは無期限・アカウント全アプリ共用・上限 2 個）。
2. **Firebase Console への登録** — プロジェクト設定 → Cloud Messaging → Apple アプリ構成 → APNs 認証キーをアップロード（Key ID / Team ID を入力）。
3. **Xcode の capability 追加** — アプリターゲットに Push Notifications と Background Modes（Remote notifications）を追加。自動署名なら App ID / プロビジョニングは Xcode が更新する（entitlements 差分はコミット対象）。Widget Extension 側には不要。
4. **Blaze への移行** — Firebase Console でプラン変更（請求先アカウント＝クレジットカード登録が必要）。同時に Cloud Billing の予算アラートを ¥500/¥1,000/¥3,000 で設定（§7.4 踏襲）。
5. **Functions 初回デプロイ** — ローカルに Node.js 20 と firebase-tools を用意し `firebase login` → `firebase deploy --only functions`。初回は Cloud Build / Artifact Registry / Cloud Run API の有効化プロンプトに承認。（2 回目以降は将来 CI 化可能）
6. **実機での配信確認** — 開発ビルド（development APNs）と TestFlight（production APNs）の両方で、バックグラウンド時にウィジェットが更新されることを確認。
7. **App Store Connect の App Privacy 申告確認** — FCM トークン（デバイス識別子相当）の収集が「識別子」区分で申告済みかを確認・更新（Firebase の開示ガイダンス参照。Analytics リンク済みのため既存申告との整合確認のみの可能性が高い）。

### 5.5 機能1 だけ先に出す選択肢の是非 → **強く推奨（採用すべき）**

1. **リスクの非対称性**: 機能1 は依存ゼロ・1 ファイル・審査上の新規要素ゼロ。機能2 は過去の意思決定の変更（Blaze）・アカウント作業・新インフラ運用（Functions のログ監視・デプロイ）を伴う。束ねると機能1 の確実なリリースが機能2 の段取りに人質に取られる。
2. **体験の下支えは機能1 で成立する**: 現状でもアプリ起動のたびに最新化される。15 分ローテーションが入れば「ホーム画面で動いている感」は達成され、機能2 が足すのは「アプリを開かない時間帯の鮮度」のみ。しかも §4.6 の制約で機能2 の実効鮮度も結局 15 分粒度に丸められるため、体感差は期待値ほど大きくない。
3. **切り分け**: ウィジェット関連は T21 のような環境依存の不具合が出やすい領域。ローテーション変更とプッシュ導入を別リリースにすれば、問題発生時の原因切り分けが単純になる。
4. **審査戦略**: 直近にリジェクト履歴があるため、1.1 は「審査面で議論の余地のない変更だけ」で構成するのが安全。Background Modes・プッシュ関連の新規宣言は 1.2 に回す。

**推奨リリース計画**: 1.1 = 機能1（T24）。1.2 = 機能2（T25〜T27、Blaze 承認後）。

---

## 6. 審査への影響評価

### 機能1

なし。WidgetKit の標準タイムライン機構のパラメータ変更のみで、権限・バックグラウンド実行・ネットワーク挙動に変化がない。

### 機能2

| 観点 | 評価 |
|---|---|
| 通知の許可プロンプト | **不要（出さない）**。`content-available` のみのサイレントプッシュは通知許可と無関係に配信され、`registerForRemoteNotifications()` はプロンプトを表示しない。よって「許可を求めるのに通知機能が見当たらない」型の審査指摘は構造的に発生しない。将来、可視通知（フォローリクエスト等）を追加する時点で初めて `UNUserNotificationCenter` の許可 UI を設計する（要確認事項 #16） |
| Guideline 2.5.4（Background Modes の正当利用） | `remote-notification` モードの用途は「ウィジェット/アプリ内コンテンツの更新」であり、Apple が明示的に認める正当用途。位置情報・オーディオ等の常駐系モードは使わない。Review Notes に「サイレントプッシュは友達の新規投稿時にホーム画面ウィジェットを最新化するために使用」と一文記載する |
| Guideline 4.5.4（プッシュ必須化の禁止） | プッシュが配信されなくてもアプリ・ウィジェットは全機能動作する（劣化は鮮度のみ）。適合 |
| App Privacy | FCM トークン収集の申告確認が必要（§5.4-7）。新たなトラッキング（ATT）は発生しない |
| 電力・パフォーマンス | スロットル（§4.6）により起床頻度は自主制限されており、2.5.4 の趣旨（不必要なバックグラウンド実行の抑制）と整合 |
| 総合 | リスク低。ただしリジェクト履歴のあるアプリなので、1.2 提出時の Review Notes でプッシュの用途を先回りして説明する |

---

## 7. 実装タスク分割（T24〜T27）

審査対応設計書の番号体系を継続する。各タスク 1 コミット・独立セッション、共通完了条件（アプリ＋Widget ターゲットのビルドが通ること）も同様。

| # | タスク | 依存 | 対象 | 完了条件（要旨） |
|---|---|---|---|---|
| T24 | 【1.1】ローテーション 15 分化と位相アライン | なし | `PeepholeWidget.swift` | 15 分境界（:00/:15/:30/:45）で表示が切り替わる。リロードしても位相が保たれる。空状態の `.after` が 4 時間になる。posts 1 件時は単一エントリ。実機の Large で 48 エントリが欠落なく表示される |
| T25 | 【1.2】プッシュ受信基盤（capability / トークン登録） | Blaze 承認（#15）＋APNs 手作業 §5.4-1〜3 | entitlements / Info.plist / `PeepholeApp.swift` / `PushService.swift`（新規）/ `firestore.rules` / `UserService` / `AuthViewModel` | 起動後に `users/{uid}/private/push` に FCM トークンが保存される。ログアウト・アカウント削除でトークンが消える。許可プロンプトが表示されない。rules で本人以外の read/write が拒否される |
| T26 | 【1.2】Cloud Functions onPostCreated | T25、§5.4-4〜5 | `functions/`（新規）、`firebase.json` | 投稿作成でフォロワー端末にサイレントプッシュが届く（実機・バックグラウンドで確認）。投稿者自身には飛ばない。無効トークンが削除される |
| T27 | 【1.2】プッシュ起床ハンドラとスロットル | T25, T26 | `PeepholeApp.swift` / `SharedDataManager` | バックグラウンドの端末で、友達の投稿後にウィジェットが（スロットル範囲内で）更新される。15 分以内の連続プッシュでは reload が 1 回に抑制される。force-quit 時に何も起きない（クラッシュしない）ことを確認 |

実施順: **T24（1.1 リリース）→ #15 の意思決定 → T25 → T26 → T27（1.2 リリース）**

---

## 8. 要確認事項（#15〜#18）

審査対応設計書 §9 の番号を継続する。**#15 が機能2 全体のゲート**であり、未回答でも T24（機能1）は着手・リリース可能。

15. **Blaze 承認の再判断**: §9.1 #1 で「Blaze は承認しない」と決定済みだが、機能2 は Cloud Functions が必須のため承認が前提になる。§5.2 の試算（想定規模で ¥0〜数百円/月、予算アラート設定）を踏まえ、承認するか。承認しない場合、機能2 は見送り（機能1 のみ実施）となる。
    - デフォルト案: 1.1（機能1）を先に出し、Blaze 判断は 1.2 の計画時に行う。
16. **可視プッシュ通知の将来計画**: フォローリクエスト等の通知を将来出す予定はあるか。予定があるなら T25 の時点でペイロードの `type` 分岐と許可リクエスト UI の置き場所（オンボーディングではなく文脈提示を推奨)を設計に含めたい。
    - デフォルト案: 今回はサイレント専用として設計し（本ドキュメントの通り）、可視通知は必要になった時点で別途設計。
17. **複数端末対応の要否**: FCM トークンを単一ドキュメント（§4.2 採用案）とするか、端末ごとのサブコレクションにするか。iPad 併用ユーザーは後者でないと片方の端末にしか届かない。
    - デフォルト案: 単一ドキュメント（最後にログインした端末が有効）。
18. **プッシュ→reload のスロットル間隔**: 15 分（機能1 のローテーション間隔と統一。§4.6）で良いか。
    - デフォルト案: 15 分。
