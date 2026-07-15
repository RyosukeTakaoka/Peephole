# App Store 審査リジェクト対応 設計ドキュメント

対象: Peephole (WidgetKit ベース SNS iOS アプリ / SwiftUI)
作成日: 2026-07-15
スコープ: 実装なし。設計のみ。

---

## 0. 現状のアーキテクチャ要約

コードを実際に読んで把握した範囲を記す。

### 0.1 全体構成

- **UI**: SwiftUI、MVVM。`Views/*Screen.swift` + `ViewModels/*ViewModel.swift`(`@MainActor` `ObservableObject`) + `Services/*Service.swift`(singleton `.shared`、Firebase SDK の薄いラッパー)という3層構成が全画面で一貫している。
- **エントリポイント**: `PeepholeApp.swift` → `RootView` が `AuthViewModel.isInitializing / isAuthenticated` を見て `LoadingView` / `WelcomeScreen` / `MainTabView` を出し分ける。EULA・同意系のゲートは一切存在しない。
- **タブ構成**(`MainTabView.swift`): ホーム(タイムライン) / 発見(未実装プレースホルダ) / 投稿(モーダル sheet) / 通知(フォローリクエストのみ) / プロフィール。
- **BaaS**: Firebase(`FirebaseManager.swift` が `Auth` / `Firestore` のシングルトン参照を保持)。**Cloud Functions・サーバーサイドロジックは一切存在しない**(`functions/` ディレクトリなし、`firebase.json` もリポジトリに未コミット)。Firestore セキュリティルールもリポジトリ内に見当たらない(Firebase コンソール側で管理されている可能性、要確認)。
- **画像ストレージ**: Firebase Storage ではなく **Cloudinary**(`CloudinaryService.swift`)。unsigned upload preset を使ったクライアント直POST。API secret はクライアントに存在しない(想定通り)。
- **ウィジェット連携**: App Group `group.app.takaoct.com.peephole.shared`(entitlements で確認)経由で `SharedDataManager` が JSON ファイル(`widgetData.json`)を読み書き。`Models.swift`(`Post`/`Song`/`PeepholeUser`/`WidgetData`)はアプリ・ウィジェット両ターゲットで共有される「Firebase 非依存」モデル。Firestore 用モデル(`FirestoreUser`/`FirestorePost`/`FirestoreFollow*`)はアプリ側専用で、ウィジェットは関与しない。`WidgetDataUpdater`(アプリ専用)がログイン中/フォアグラウンド復帰/投稿作成後に Firestore→Widget データへの変換・保存・タイムラインリロードを行う。

### 0.2 Firestore コレクション(現状)

| コレクション | 用途 | モデル |
|---|---|---|
| `users` | ユーザープロフィール | `FirestoreUser`(`UserService.swift`) |
| `posts` | 投稿 | `FirestorePost`(`PostService.swift`) |
| `follows` | 成立済みフォロー関係 | `FirestoreFollow`(`FollowService.swift`) |
| `followRequests` | フォロー申請(鍵アカウント前提、`isPrivate: true` が新規作成時に固定でセットされる) | `FirestoreFollowRequest` |

**ブロック・通報関連のコレクション/モデルは一切存在しない。**

### 0.3 認証・アカウント削除の現状

- `AuthenticationService.swift` に `deleteAccount()` が実装済みだが、**`Auth.currentUser?.delete()` を呼ぶだけ**で Firestore 側(`users`/`posts`/`follows`/`followRequests`)は一切削除しない。
- `AuthViewModel.deleteAccount()` も存在するが、内部に `// TODO: Firestoreのユーザーデータを削除` というコメントが残ったままで未完成。
- 決定的な問題: **この `deleteAccount()` を呼び出す UI が どこにも存在しない**。`ProfileScreen.swift` 内 `SettingsView` にはログアウトボタンしかない。つまりアプリ内にアカウント削除の入口が存在しない(Guideline 5.1.1(v) 該当)。

### 0.4 「プロフィールを編集」ボタンの現状(重要)

`Peephole/Views/Profile/ProfileScreen.swift:36-46`:

```
Button {
    // 将来的な実装: EditProfileScreenへ遷移
} label: { Text("プロフィールを編集") ... }
```

**アクションクロージャが空**。`EditProfileScreen` に相当するファイルはリポジトリ内に存在しない。つまりこのボタンは iPad 固有ではなく **全デバイスで無条件に無反応**。詳細は §3 参照。

一方 `ProfileViewModel.swift` には `updateProfile(displayName:bio:)` / `updateProfileImage(_:)` が、`UserService.swift` には `updateUsername(userId:newUsername:)` がすでに実装済みで未使用のまま存在する。編集画面がないだけで、更新ロジックの大半はすでにある。

### 0.5 モデレーション/UGC対策の現状

- 投稿作成(`PostCreateViewModel.createPost`)にテキスト・画像フィルタリングは一切なし。長さ制限のみ。
- 投稿・プロフィールに「通報」「ブロック」のUI導線は存在しない(`HomeScreen.swift` の `PostCardView`、`UserProfileScreen.swift` にメニューボタン等なし)。
- EULA/利用規約同意フローなし(`WelcomeScreen`/`LoginScreen`/`SignUpScreen` いずれにも同意チェックボックス・画面がない)。

### 0.6 その他

- `TARGETED_DEVICE_FAMILY = "1,2"`(iPhone + iPad 対応)。iPad 固有の分岐(`UIUserInterfaceIdiom` 判定など)はコード中に一切ない。
- `fastlane`/スクリーンショット生成用ディレクトリはリポジトリに存在しない → App Store のスクリーンショット差し替え(リジェクト理由4)は **コードの問題ではなく App Store Connect 上のアセット差し替え作業**であり、本設計書のスコープ外(§要確認事項に記載)。

---

## 1. Guideline 1.2 — UGC対策(EULA・フィルタリング・通報・ブロック・24時間対応)

現状バックエンドが「Firestore に対するクライアント直接読み書きのみ」であるため、この要件を満たすには **新たに Cloud Functions によるサーバーサイド処理を追加する**必要がある(特に「画像フィルタリング」「ブロック時の開発者通知」「24時間以内対応の追跡」はクライアントだけでは実現不可能、または信頼できない)。

### 1.1 EULA 同意(登録/ログイン前に提示)

**方針**: アプリ初回起動時、`WelcomeScreen` を表示する前に同意画面を `fullScreenCover` で強制表示。ローカル(UserDefaults)フラグで再表示を抑止しつつ、アカウント作成時にはサーバー側(Firestore)にも同意日時を記録し監査可能にする。

**新規/変更ファイル**

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Views/Legal/EULAConsentScreen.swift` | 新規 | EULA/利用規約本文表示 + 「同意する」ボタン。同意するまで裏の `WelcomeScreen` を操作不可にする全画面カバー。 |
| `Peephole/Services/LegalAgreementService.swift` | 新規 | `hasAcceptedEULALocally: Bool`(UserDefaults 読み書き)、`recordAcceptance(userId:)`(ログイン済みユーザーの Firestore `eulaAcceptedAt` を更新)。 |
| `Peephole/PeepholeApp.swift` | 変更 | `RootView.body` に `.fullScreenCover(isPresented: !hasAcceptedEULA)` 相当のロジックを追加。EULA 未同意なら `WelcomeScreen`/`MainTabView` より最優先で表示。 |
| `Peephole/Services/UserService.swift` | 変更 | `FirestoreUser` に `eulaAcceptedAt: Date?` を追加。`createUserProfile` 呼び出し時に併せてセット。 |
| `Peephole/ViewModels/AuthViewModel.swift` | 変更 | `signUp` 成功後に `LegalAgreementService.recordAcceptance(userId:)` を呼ぶ。 |

**データモデル変更**

- `FirestoreUser` に `eulaAcceptedAt: Date?` を追加(新規作成時に必須でセット。既存ユーザーには存在しない= `nil` のまま許容し、次回ログイン時に補完更新するマイグレーション処理を `AuthViewModel` の認証状態リスナー内に追加)。

**画面遷移**

```
起動 → RootView
  ├─ ローカルにEULA未同意 → EULAConsentScreen(fullScreenCover, 閉じられない)
  │     「同意する」タップ → ローカルフラグ保存 → 通常フローへ
  └─ 同意済み → 従来通り LoadingView / WelcomeScreen / MainTabView
```

同意画面は認証状態に関わらず最優先で出す(未ログインでもログイン済みでも、ローカルフラグが立っていなければ表示)。

### 1.2 不適切コンテンツのフィルタリング

**方針**: クライアント側の即時フィルタ(テキストの禁止語チェック、投稿前フィードバック用)+ サーバー側(Cloud Functions)の非同期フィルタ(画像・テキストの二重チェック、悪意あるクライアントのバイパス対策)の二段構え。

**バックエンド変更(要新規追加): Firebase Cloud Functions**

現状 Cloud Functions が存在しないため、`functions/` ディレクトリを新設(Node.js/TypeScript, Firebase Functions v2)。

| ファイル | 種別 | 責務 |
|---|---|---|
| `functions/package.json`, `functions/tsconfig.json`, `firebase.json` | 新規 | Cloud Functions プロジェクトの雛形。 |
| `functions/src/moderateNewPost.ts` | 新規 | `posts/{postId}` の `onCreate` トリガー。`imageURL` に対して Cloud Vision API の SafeSearch Detection を実行し、しきい値(`LIKELY`/`VERY_LIKELY` for adult/violence/racy)を超えたら該当 `posts` ドキュメントの `moderationStatus` を `"hidden"` に更新し、`moderationActions` コレクションに監査ログを1件作成する。テキスト(`text` フィールド)についても Cloud Natural Language API 等で毒性スコアを判定し、同様に反映する。 |
| `functions/src/lib/moderation.ts` | 新規 | Vision/NL API 呼び出しの共通ロジック。 |

**クライアント側変更**

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Services/ContentFilterService.swift` | 新規 | 投稿テキストに対する即時の禁止語チェック(バンドルした JSON 語彙リストとの照合)。サーバー判定の代替ではなく、あくまで即時フィードバック用の一次防衛線。 |
| `Peephole/Resources/ProhibitedWords.json`(または `Assets` 内) | 新規 | 禁止語リスト(日本語/英語)。 |
| `Peephole/ViewModels/PostCreateViewModel.swift` | 変更 | `createPost` の冒頭で `ContentFilterService` によるテキストチェックを追加。NG ワード検出時はアップロード前にエラー表示して中断。 |
| `Peephole/Services/PostService.swift` | 変更 | `FirestorePost` に `moderationStatus: String`(`"visible"` / `"hidden"` / `"underReview"`)を追加。`createPost` 時は常に `"visible"` で作成(非同期でサーバーが降格させる方式。同期プリスクリーンにすると投稿体験が悪化するため)。 |
| `Peephole/Services/PostService.swift` | 変更 | `getTimelinePosts` / `getUserPosts`(他人の投稿として見る場合)/ `getWidgetPosts` の Firestore クエリに `.whereField("moderationStatus", isEqualTo: "visible")` を追加。自分自身の投稿一覧(`ProfileScreen`)は所有者には `hidden` でも見える(理由表示付き)ようにするため、`getUserPosts` に `includeHidden: Bool` パラメータを追加し、`ProfileViewModel` からの呼び出しのみ `true` を渡す。 |
| `Peephole/Services/WidgetDataUpdater.swift` | 変更 | `getTimelinePosts` 経由になるため自動的に `visible` のみ反映される(変更不要、間接的に対応)。 |

**データモデル変更まとめ**

- `FirestorePost` に `moderationStatus: String`(default `"visible"`)、`moderationReason: String?` を追加。
- 新規コレクション `moderationActions`: `{ actionId, targetType: "post"|"user", targetId, reason, source: "auto"|"report", createdAt, resolvedAt: Date? }`。24時間対応SLAの追跡台帳を兼ねる(§1.5)。

**Firestore インデックス**: `posts` の `userId + isExpired + moderationStatus + createdAt` および `userId in [...] + isExpired + moderationStatus + createdAt` の複合インデックスを追加デプロイする必要がある(Firestore コンソールまたは `firestore.indexes.json` に追記)。

### 1.3 通報機能

**新規/変更ファイル**

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Services/ReportService.swift` | 新規 | `FirestoreReport` モデル定義 + `submitReport(reporterId:targetType:targetId:reason:detail:)`。`reports` コレクションへの書き込み。 |
| `Peephole/Views/Moderation/ReportSheet.swift` | 新規 | 通報理由選択(スパム/不適切な画像/嫌がらせ・誹謗中傷/その他)+ 詳細テキスト入力の `sheet` UI。投稿・ユーザー両方から再利用できる汎用コンポーネント。 |
| `Peephole/ViewModels/ReportViewModel.swift` | 新規 | `ReportSheet` の状態管理(選択理由、送信中フラグ、送信結果)。 |
| `Peephole/Views/Main/HomeScreen.swift` | 変更 | `PostCardView` にコンテキストメニュー(`.contextMenu` または `Menu` の「…」ボタン)を追加し、「投稿を通報」「ユーザーをブロック」を配置。 |
| `Peephole/Views/Profile/UserProfileScreen.swift` | 変更 | ツールバーに「…」メニューを追加し、「ユーザーを通報」「ユーザーをブロック」を配置。 |
| `Peephole/ViewModels/HomeViewModel.swift` | 変更 | 通報シートを開くための `@Published var reportTarget:` のような状態を追加(または `PostCardView` 側で直接 `ReportViewModel` を保持)。 |

**データモデル**

新規コレクション `reports`:

| フィールド | 型 | 説明 |
|---|---|---|
| `reportId` | String | ドキュメントID |
| `reporterId` | String | 通報者UID |
| `targetType` | String | `"post"` \| `"user"` |
| `targetId` | String | 投稿ID or ユーザーID |
| `reason` | String | enum(スパム/不適切画像/嫌がらせ/その他) |
| `detail` | String? | 自由記述 |
| `status` | String | `"pending"` \| `"reviewed"` \| `"actioned"` \| `"dismissed"` |
| `createdAt` | Date | |
| `reviewedAt` | Date? | |

**バックエンド変更**

| ファイル | 種別 | 責務 |
|---|---|---|
| `functions/src/onReportCreated.ts` | 新規 | `reports/{reportId}` の `onCreate` トリガー。開発者(運営者)にメール通知(§1.5)。同一 `targetId` への `pending` 通報数がしきい値(例: 3件)を超えたら該当投稿/ユーザーを自動的に一時非表示(投稿は `moderationStatus = "underReview"`、ユーザーは後述 `restrictionStatus`)にし、`moderationActions` に記録する。 |

### 1.4 ユーザーのブロック機能

**要件の分解**:
1. ブロックしたら相手のコンテンツが**即座に**自分のフィードから消える。
2. ブロック発生時に開発者に通知する。
3. フォロー関係の解消(相互)。

**新規/変更ファイル**

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Services/BlockService.swift` | 新規 | `FirestoreBlock` モデル + `blockUser(blockerId:blockedId:)`(トランザクション: `blocks` ドキュメント作成 + 双方向の `follows`/`followRequests` を削除しフォロワー/フォロー数を補正)、`unblockUser(...)`、`getBlockedIds(for:) -> [String]`(自分がブロックした相手)、`getBlockerIds(of:) -> [String]`(自分をブロックした相手。逆方向のコンテンツ非表示にも必要)、`isBlocked(between:and:) -> Bool`。 |
| `Peephole/ViewModels/HomeViewModel.swift` | 変更 | `loadTimeline` で `FollowService.getFollowingIds` 取得後、`BlockService.getBlockedIds` と `getBlockerIds` の両方を差し引いた `targetUserIds` で `PostService.getTimelinePosts` を呼ぶ。 |
| `Peephole/Services/WidgetDataUpdater.swift` | 変更 | 同様に `updateWidgetWithFollowingPosts` 内でブロック双方向のユーザーIDを除外してから `getTimelinePosts` を呼ぶ。 |
| `Peephole/ViewModels/UserProfileViewModel.swift` | 変更 | `loadUserProfile` の冒頭で `isBlocked` をチェックし、ブロック関係(どちらの方向でも)があれば `followStatus` とは別の `isBlockedRelationship: Bool` を立て、フォローボタンの代わりに「ブロック中です」表示 + 投稿非表示にする。`handleFollowButtonTapped` にブロック中は何もしないガードを追加。`blockUser()` / `unblockUser()` の呼び出しラッパーを追加。 |
| `Peephole/Views/Profile/UserProfileScreen.swift` | 変更 | 「…」メニューに「ブロックする」/ブロック済みなら「ブロック解除」を表示。ブロック実行後は即座に `dismiss()` して一覧に戻る。 |

**データモデル**

新規コレクション `blocks`:

| フィールド | 型 | 説明 |
|---|---|---|
| `blockId` | String | |
| `blockerId` | String | ブロックした人 |
| `blockedId` | String | ブロックされた人 |
| `createdAt` | Date | |

**バックエンド変更**

| ファイル | 種別 | 責務 |
|---|---|---|
| `functions/src/onBlockCreated.ts` | 新規 | `blocks/{blockId}` の `onCreate` トリガー。①開発者へメール通知(§1.5)。②クライアント側トランザクションが失敗した場合の保険として、サーバー側でも `follows`/`followRequests` の双方向削除を再実行(冪等に設計)。 |

### 1.5 24時間以内対応フロー

ここは「コードだけで完結しない業務プロセス」を含むため、コード側でできることと運用側で必要なことを分けて設計する。

**コード側(自動化できる部分)**

| ファイル | 種別 | 責務 |
|---|---|---|
| `functions/src/lib/notifyDeveloper.ts` | 新規 | Firebase Extension「Trigger Email from Firestore」(`mail` コレクションへの書き込みでメール送信)、または SendGrid/Nodemailer を使ったメール送信の共通関数。`onReportCreated.ts` / `onBlockCreated.ts` から呼ばれる。件名・本文に対象の種別・ID・Firestore コンソールへのディープリンクを含める。 |
| `functions/src/checkOverdueModeration.ts` | 新規 | 毎時実行のスケジュール関数(`onSchedule`)。`moderationActions` / `reports` のうち `status == "pending"` かつ `createdAt` が23時間以上前のものを検出し、開発者にリマインドメールを送る(SLA逸脱防止のセーフティネット)。 |

**運用側(コード外で決める必要がある事項)**

- 実際に24時間以内に「対応する」担当者・体制(ソロ開発であれば運営者自身がメール通知を受けて Firestore コンソールから `moderationActions`/`reports` の `status` を更新し、必要なら該当 `posts`/`users` ドキュメントを手動で `moderationStatus`/`restrictionStatus` 変更する、という運用を明文化する)。
- これは §要確認事項 に記載し、ユーザー側の意思決定を仰ぐ。

---

## 2. Guideline 5.1.1(v) — アカウント削除機能

現状 `AuthenticationService.deleteAccount()` は Firebase Auth ユーザーのみを削除し、Firestore データは残る。かつ呼び出し口がアプリ内に存在しない。Firebase の `user.delete()` は **再認証(recent login)が必須**でエラーになりやすく、クライアントから直接呼ぶ設計は壊れやすい。したがって「即時のクライアント削除」ではなく「アプリ内から削除をリクエストし、サーバー(Cloud Functions)が確実にカスケード削除する」方式に変更する。

### 2.1 設計方針

1. ユーザーがアプリ内で削除をリクエストすると、**同期的に**: Firestore の `users/{uid}` に `isDeletionRequested: true`, `deletionRequestedAt: serverTimestamp()` を書き込み、即座にサインアウトしてローカルのウィジェットデータもクリアする。この時点でアプリ上の体験としてはアカウントは完全に使用不能になる(Apple 要件の「アプリ内から削除を開始できる」を満たす)。
2. Cloud Functions がこのフラグの変化をトリガーに、**非同期で**カスケード削除(投稿、フォロー関係、フォローリクエスト、通報、ブロック、Cloudinary 画像、最後に Firebase Auth ユーザー本体)を実行する。

### 2.2 新規/変更ファイル

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Views/Profile/SettingsScreen.swift` | 新規(`ProfileScreen.swift` 内 `SettingsView` を抽出・拡張) | 既存の「ログアウト」セクションに加え、「アカウントを削除」セクションを追加。他画面(`LoginScreen.swift` 等)と同様に1画面1ファイルの規約に合わせて独立ファイル化する。 |
| `Peephole/Views/Profile/DeleteAccountConfirmationView.swift` | 新規 | 削除の影響説明(投稿・フォロー関係・すべてのデータが失われる旨)+ 確認入力(例: 「削除」と入力させる)+ 破壊的确認ボタン。 |
| `Peephole/Views/Profile/ProfileScreen.swift` | 変更 | インライン定義の `SettingsView` を削除し `SettingsScreen()` を参照するよう変更。 |
| `Peephole/Services/AuthenticationService.swift` | 変更 | 既存の `deleteAccount()`(直接 `user.delete()` を呼ぶ版)は削除し、代わりに何もクライアントからは Auth ユーザーを消さない設計にする(Cloud Functions の Admin SDK に一任)。 |
| `Peephole/Services/UserService.swift` | 変更 | `requestAccountDeletion(userId:)` を追加。`users/{uid}` に `isDeletionRequested: true`, `deletionRequestedAt: FieldValue.serverTimestamp()` を `updateData`。 |
| `Peephole/ViewModels/AuthViewModel.swift` | 変更 | `deleteAccount()` を書き換え、`UserService.requestAccountDeletion(userId:)` → 成功したら即 `logout()` を呼ぶフローにする(TODO コメント・旧実装を置き換え)。 |
| `Peephole/Services/PostService.swift` | 変更 | `getTimelinePosts` 等のクエリ結果から `isDeletionRequested == true` のユーザーの投稿を除外する必要があるが、投稿ドキュメントに直接そのフラグはないため、削除リクエスト時に Cloud Functions が該当ユーザーの全投稿の `moderationStatus` を即座に `"hidden"` にする一手を先頭で実行する(§2.3)ことで対応し、クライアント側の追加クエリ条件は不要とする。 |

### 2.3 バックエンド変更(Cloud Functions)

| ファイル | 種別 | 責務 |
|---|---|---|
| `functions/src/onAccountDeletionRequested.ts` | 新規 | `users/{uid}` の `onUpdate` トリガー。`isDeletionRequested` が `false→true` に変化した時のみ発火。処理順序: ①該当ユーザーの `posts` を全件 `moderationStatus = "hidden"` に更新(即時に他人のフィードから消す)。②`follows`(双方向)・`followRequests`(双方向)を削除しカウンタ補正。③`blocks`(双方向)を削除。④`reports` は当人が通報者の場合は `reporterId` を匿名化(削除ではなく監査ログ保持のため)、当人が対象の場合はそのまま残す(モデレーション記録保持)。⑤Cloudinary Admin API(`destroy`)で当該ユーザーがアップロードした画像を削除(要 Cloudinary API Key/Secret を Functions のシークレットとして新規設定)。⑥`posts` ドキュメント本体を削除。⑦`users/{uid}` ドキュメントを削除。⑧Firebase Admin SDK (`admin.auth().deleteUser(uid)`) で Auth アカウントを削除。 |

### 2.4 データモデル変更

- `FirestoreUser` に `isDeletionRequested: Bool`(default `false`)、`deletionRequestedAt: Date?` を追加。
- Cloudinary の API Key/Secret を Cloud Functions の環境シークレットとして新規に用意する必要がある(現在クライアントは unsigned preset のみ使用しており secret を保持していない → 新規発行・設定が必要。要確認事項)。

### 2.5 画面遷移

```
ProfileScreen → (歯車アイコン) → SettingsScreen
  └─ 「アカウントを削除」 → DeleteAccountConfirmationView(sheet)
        「削除」と入力 + 確認ボタン
          → AuthViewModel.deleteAccount()
               → UserService.requestAccountDeletion(userId:)
               → authViewModel.logout()
               → RootView が自動的に WelcomeScreen に遷移(既存の状態監視ロジックそのまま活用)
```

---

## 3. Guideline 2.1(a) — 「プロフィールを編集」ボタン無反応(iPad)

### 3.1 コード調査で判明した事実

`ProfileScreen.swift:36-46` のボタンはアクションクロージャが空であり、**タップしても何も起きないのは iPhone / iPad 問わず常に発生する**。`EditProfileScreen` に相当する画面ファイルはリポジトリ全体を検索しても存在しない。つまりこれは「iPad 特有の不具合」ではなく「機能が未実装のまま UI だけ用意されている」状態であり、レビュアーがたまたま iPad Air (M3) で検証した際に踏んだだけと考えるのが最も自然である。

### 3.2 仮説と検証方法(複数列挙)

| # | 仮説 | 検証方法 |
|---|---|---|
| 1 | **(最有力・静的解析で確認済み)ボタンのアクションクロージャが空で未実装** | ソースコードを読む(実施済み・確認済み)。iPhone シミュレータで同ボタンをタップし、iPad と同様に無反応であることを再現して「iPad固有ではない」ことを実証する。 |
| 2 | iPad のマルチタスキング(Split View / Slide Over)や広い横幅レイアウトでのヒットテスト不整合(`ScrollView` 内 `VStack` のフレーム計算ズレ、`ZStack` の `isLoading` 分岐で見えない `ProgressView` オーバーレイがタップを奪っている等) | iPad シミュレータ(iPad Air 11-inch M3 / iPadOS 26.5.2 相当)で実機起動し、Xcode の "Debug View Hierarchy" でボタンをタップした瞬間のビュー階層を確認。ボタンの上に透明なビューが重なっていないか、`isLoading` が意図せず `true` のまま残っていないかを確認する。 |
| 3 | 別の sheet(`showSettings` など)が透明な状態で残っており、タップイベントを奪っている | `showSettings` を含む `@State` の初期値・遷移ロジックを再確認(実施済み・単一の bool のみで疑わしい多重 sheet はなし)。iPad実機/シミュレータで「設定」を開いて閉じた直後に編集ボタンをタップし、再現するか確認。 |
| 4 | iPad の Magic Keyboard/トラックパッドのポインタ操作とタッチ操作でのヒットテスト挙動差(カスタム `.onTapGesture` 等が `Button` と競合) | 該当ボタン周辺にカスタムジェスチャは存在しない(実施済み・確認済み、`Button` のみ)。念のため実機でトラックパッド/マウスクリックと指タップの両方で再現するか比較する。 |
| 5 | プロフィール読み込み失敗によりボタンが属する分岐(`else if let profile = viewModel.userProfile`)自体がレンダリングされておらず、レビュアーには「ボタンが見えているのに反応しない」ように見えているだけ(実際は別要素) | `ProfileViewModel.loadProfile` 内の `print("❌ Failed to load profile...")` ログを、審査用テストアカウントで iPad 実機/シミュレータ実行時に Xcode コンソールで確認する。Firestore の権限エラー等でプロフィール取得自体が失敗していないかを切り分ける。 |

### 3.3 修正設計

既存の `ProfileViewModel` にはすでに `updateProfile(displayName:bio:)` / `updateProfileImage(_:)` が実装済みで、`UserService` にも `updateUsername(userId:newUsername:)` が実装済み。**画面を新設して繋ぎ込むだけで完結する**。

**新規/変更ファイル**

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Views/Profile/EditProfileScreen.swift` | 新規 | 表示名・ユーザー名・自己紹介の編集フォーム + `PostCreateScreen.swift` と同様の `PhotosPicker` によるプロフィール画像変更。「保存」/「キャンセル」。 |
| `Peephole/ViewModels/ProfileViewModel.swift` | 変更 | `updateUsername(_ newUsername: String) async -> Bool` を追加(`UserService.updateUsername` の薄いラッパー。エラー時は `showError` を立てて `false` を返す)。`saveProfileEdits(displayName:username:bio:newImage:)` のような一括保存メソッドを追加し、変更があったフィールドのみ更新処理を呼ぶ(ユーザー名は変更時のみ重複チェック込みで呼ぶ)。 |
| `Peephole/Views/Profile/ProfileScreen.swift` | 変更 | 空だったボタンアクションを `showEditProfile = true` に変更し、`.sheet(isPresented: $showEditProfile) { EditProfileScreen(viewModel: viewModel) }` を追加。 |

**画面遷移**

```
ProfileScreen
  └─ 「プロフィールを編集」タップ
        → EditProfileScreen(sheet)
             表示名 / ユーザー名 / 自己紹介 / プロフィール画像 を編集
             「保存」→ ProfileViewModel.saveProfileEdits(...)
                         → 成功: dismiss、ProfileScreen は既存の `refreshProfile()` 相当で最新化
                         → 失敗: 既存の `showError`/`errorMessage` アラートで表示
             「キャンセル」→ 破棄して dismiss
```

---

## 4. 実装タスクリスト(依存関係順・1タスク=1コミット相当)

各タスクは Sonnet が実装する前提で、曖昧さを残さないよう完了条件を明記する。

### Phase A: 即修正・独立タスク

**A1. プロフィール編集画面の実装(Guideline 2.1(a) 修正)**
- 内容: §3.3 の通り `EditProfileScreen.swift` 新設、`ProfileViewModel` に `updateUsername`/`saveProfileEdits` 追加、`ProfileScreen.swift` のボタン配線。
- 完了条件:
  - `ProfileScreen.swift` のボタンタップで `EditProfileScreen` が sheet 表示される。
  - 表示名・自己紹介・ユーザー名(重複時はエラー表示)・プロフィール画像を編集し保存すると、Firestore の `users/{uid}` が更新され、`ProfileScreen` に戻った時点で表示が最新化されている。
  - 保存失敗時(ネットワークエラー等)は既存の `showError` アラートパターンで表示される。
  - iPhone・iPad 双方のシミュレータでビルド・動作確認済み。
  - 既存の `PeepholeTests`/`PeepholeUITests` がビルド・パスする。

**A2. EULA 同意フローの実装**
- 内容: §1.1 の通り `EULAConsentScreen.swift`、`LegalAgreementService.swift` 新設、`PeepholeApp.swift` の `RootView` 変更、`FirestoreUser.eulaAcceptedAt` 追加。
- 完了条件:
  - アプリ初回起動時(ローカルに同意記録なし)、`WelcomeScreen` より先に `EULAConsentScreen` が表示され、「同意する」をタップするまで他の画面を操作できない。
  - 一度同意すると、アプリ再起動後も再表示されない(UserDefaults に永続化)。
  - サインアップ完了時、Firestore の `users/{uid}.eulaAcceptedAt` に日時が記録される。
  - アプリをアンインストール→再インストールした場合は再度 EULA が表示される(ローカル永続化の仕様として許容)。

### Phase B: バックエンド基盤(Phase C 以降が依存)

**B1. Firebase Cloud Functions プロジェクトの新設**
- 内容: `firebase.json`、`functions/package.json`、`functions/tsconfig.json`、空の `functions/src/index.ts` を作成し、`firebase deploy --only functions` が通る最小構成を用意する。
- 完了条件:
  - `firebase emulators:start --only functions,firestore` がローカルで起動する。
  - `functions/src/index.ts` に何もエクスポートしていない状態でも `firebase deploy --only functions --dry-run` 相当のチェックが通る。
  - README または `functions/README.md` に、GCP プロジェクトを Blaze プランに変更する必要がある旨、Cloud Vision API / Cloud Natural Language API を有効化する必要がある旨を明記する(要確認事項と対応、§末尾参照)。

**B2. Firestore データモデル拡張(投稿・ユーザーへのモデレーション用フィールド追加)**
- 内容: `FirestorePost` に `moderationStatus`・`moderationReason`、`FirestoreUser` に `isDeletionRequested`・`deletionRequestedAt` を追加。`PostService.createPost` は `moderationStatus: "visible"` で作成。
- 完了条件:
  - 新規投稿作成時、Firestore ドキュメントに `moderationStatus: "visible"` が保存されることを確認できる。
  - 既存(フィールドなし)の投稿・ユーザードキュメントを読み込んでもクラッシュしない(`Codable` のデコードが optional/default で安全に失敗しない設計になっている)。
  - `PostService.getTimelinePosts` / `getUserPosts` / `getWidgetPosts` に `moderationStatus == "visible"` フィルタが入る(`getUserPosts` は `includeHidden` パラメータ追加、`ProfileViewModel` からのみ `true`)。
  - 必要な Firestore 複合インデックスが `firestore.indexes.json` に追記され、デプロイ手順がドキュメント化されている。

### Phase C: 通報・ブロック(B に依存)

**C1. 通報機能の実装**
- 内容: §1.3 の `ReportService.swift`、`ReportSheet.swift`、`ReportViewModel.swift` 新設、`HomeScreen`/`UserProfileScreen` へのメニュー追加。
- 完了条件:
  - 投稿カードの「…」メニューから「投稿を通報」を選択すると `ReportSheet` が開き、理由選択+詳細入力+送信ができる。
  - `UserProfileScreen` のツールバーからも同様にユーザー通報ができる。
  - 送信後、Firestore の `reports` コレクションに `status: "pending"` のドキュメントが作成される。
  - 送信中は二重送信不可(ローディング状態)、送信成功後はトースト/アラートでユーザーにフィードバックがある。

**C2. Cloud Functions: 通報通知・自動非表示**
- 内容: `functions/src/onReportCreated.ts`、`functions/src/lib/notifyDeveloper.ts` 新設。
- 完了条件:
  - `reports` コレクションへの新規ドキュメント作成をトリガーに、開発者宛メールが送信される(Firebase Functions エミュレータ + メール送信のモック/ログで確認可能な形にする)。
  - 同一 `targetId` への `pending` 通報が3件以上になった場合、該当投稿の `moderationStatus` が `"underReview"` に、または該当ユーザーに一時制限が適用される処理が実装され、単体テスト(Functions のユニットテスト、`firebase-functions-test` 等)で検証されている。

**C3. ブロック機能の実装(クライアント側)**
- 内容: §1.4 の `BlockService.swift` 新設、`HomeViewModel`/`WidgetDataUpdater`/`UserProfileViewModel`/`UserProfileScreen` 変更。
- 完了条件:
  - `UserProfileScreen` からユーザーをブロックすると、Firestore の `blocks` コレクションにドキュメントが作成され、双方向の `follows`/`followRequests` が削除されカウンタが補正される(既存の `FollowService` のトランザクションパターンと同様の一貫性が保たれる)。
  - ブロック実行直後、`HomeViewModel.loadTimeline`(次回読み込み時、または即座にローカルリストからも除外)で相手の投稿が表示されなくなることを確認できる。
  - `WidgetDataUpdater` によって更新されるウィジェットデータにもブロック相手の投稿が含まれない。
  - ブロック済みユーザーのプロフィールを開くと、フォローボタンの代わりに「ブロック中」状態が表示され、フォロー操作ができない。
  - ブロック解除で元の状態(フォロー関係は復活しない、単に投稿が見えるようになる)に戻ることを確認できる。

**C4. Cloud Functions: ブロック通知・サーバー側フォールバック**
- 内容: `functions/src/onBlockCreated.ts` 新設。
- 完了条件:
  - `blocks` コレクションへの新規ドキュメント作成をトリガーに、開発者宛メールが送信される。
  - クライアントのトランザクションが何らかの理由で `follows`/`followRequests` の削除に失敗しているケースを想定し、サーバー側でも同じ削除処理を冪等に実行し、既に削除済みなら何もしない設計になっている(単体テストで冪等性を確認)。

### Phase D: コンテンツフィルタリング(B に依存)

**D1. クライアント側テキストフィルタ**
- 内容: `ContentFilterService.swift`、禁止語リソース新設、`PostCreateViewModel.createPost` への組み込み。
- 完了条件:
  - 禁止語を含むテキストで投稿しようとすると、アップロード処理(Cloudinary 通信)が開始される前にエラーメッセージが表示され投稿がブロックされる。
  - 禁止語を含まない通常のテキストは従来通り投稿できる(既存のテキスト長制限バリデーションと共存する)。

**D2. Cloud Functions: 画像・テキストのサーバー側モデレーション**
- 内容: `functions/src/moderateNewPost.ts`、`functions/src/lib/moderation.ts` 新設。
- 完了条件:
  - `posts` コレクションへの新規ドキュメント作成をトリガーに Cloud Vision SafeSearch(モック可能な形で実装、エミュレータ/ユニットテストでは API 呼び出し部分をモック)が実行され、しきい値を超えた場合に `moderationStatus` が `"hidden"` に更新される処理が実装・テストされている。
  - `moderationActions` コレクションに監査ログが1件作成される。
  - `firebase-functions-test` によるユニットテストで、SafeSearch が「問題なし」を返すケースと「NG」を返すケースの両方が検証されている。

### Phase E: アカウント削除(B に依存。C・D と並行実施可)

**E1. アカウント削除リクエストのクライアント実装**
- 内容: §2.2 の `SettingsScreen.swift` 抽出・拡張、`DeleteAccountConfirmationView.swift` 新設、`AuthenticationService.deleteAccount()` 廃止、`UserService.requestAccountDeletion`、`AuthViewModel.deleteAccount()` 書き換え。
- 完了条件:
  - `ProfileScreen` → 歯車アイコン → `SettingsScreen` に「アカウントを削除」の行が追加されている。
  - タップすると確認画面が表示され、確認テキスト入力(例:「削除」)をしないと削除ボタンが有効化されない。
  - 削除を確定すると、Firestore の `users/{uid}` に `isDeletionRequested: true` が書き込まれた上で即座にサインアウトされ、`WelcomeScreen` に戻る(`RootView` の既存の認証状態監視ロジックがそのまま機能することを確認)。
  - サインアウトと同時にローカルのウィジェットデータ(`SharedDataManager`)もクリアされる。
  - 既存の `SettingsView` からログアウト機能に回帰(regression)がないことを確認する。

**E2. Cloud Functions: カスケード削除**
- 内容: `functions/src/onAccountDeletionRequested.ts` 新設。Cloudinary Admin API 連携含む。
- 完了条件:
  - `users/{uid}.isDeletionRequested` が `false→true` に変化したことをトリガーに、§2.3 の①〜⑧の順序で処理が実行される。
  - 処理完了後、`posts`/`follows`/`followRequests`/`blocks` の当該ユーザー関連ドキュメントが全て削除されている(Firestore エミュレータ上でのユニットテストで確認)。
  - Cloudinary 上の画像削除呼び出しが行われる(Cloudinary API のモックでユニットテスト、実 API キーはシークレット管理)。
  - 最終的に Firebase Admin SDK 経由で Auth ユーザーが削除され、同じメールアドレスで新規登録が可能な状態に戻ることを確認する。
  - 処理が途中で失敗した場合に再試行可能な設計(冪等性、あるいは失敗ログを `moderationActions` 等に残す)になっている。

### Phase F: 横断的な統合・回帰確認

**F1. モデレーション横断の統合確認**
- 内容: A〜E で追加した `moderationStatus`/`isDeletionRequested`/`blocks` によるフィルタリングが、タイムライン・ウィジェット・プロフィール・検索(`UserService.searchUsers`、将来「発見」タブ実装時のため)すべてで一貫していることを確認し、漏れがあれば追加修正する。特に `UserService.searchUsers` は現状 `isDeletionRequested` を考慮していないため、削除リクエスト済みユーザーが検索結果に出ないようクエリ条件を追加する。
- 完了条件:
  - `UserService.searchUsers` が `isDeletionRequested == false`(または未設定)のユーザーのみ返す。
  - ブロック・モデレーション非表示・削除リクエスト済みのいずれかに該当する投稿/ユーザーが、タイムライン・プロフィール(他人から見た場合)・ウィジェット・検索のどこにも表示されないことを手動シナリオテストで確認し、結果を記録する。
  - `PeepholeTests`/`PeepholeUITests` に新規ケース(ブロック後にタイムラインから消える、削除リクエスト後にログイン不可になる等)が追加され、パスする。

---

## 5. 要確認事項(実装着手前にユーザーへ確認)

1. **EULA/利用規約の本文**: 独自の利用規約・プライバシーポリシーの文面/URLはすでにあるか。なければ Apple 標準 EULA を使うか、簡易な独自文面を用意するか。プライバシーポリシーの公開URL(App Store Connect にも別途登録が必要)はあるか。
2. **Cloud Functions / GCP の課金プラン**: 現在 Firebase プロジェクトが Spark(無料)プランの場合、Cloud Functions のデプロイと外部API(Cloud Vision 等)呼び出しには Blaze(従量課金)プランへの変更が必須。この変更(課金発生)を承認するか。
3. **Cloud Vision API 等の外部モデレーションAPI利用**: 画像の自動フィルタリングに Google Cloud Vision の SafeSearch Detection を使う設計にしたが、他のサービス(AWS Rekognition、Cloudinary の Moderation Add-on 等)を既に契約している、または希望するものがあるか。
4. **開発者通知メールの送信手段**: Firebase Extension「Trigger Email from Firestore」(SMTP設定が必要)を使うか、SendGrid 等の別サービスを使うか。通知先メールアドレスは `cjie46251@gmail.com` でよいか、別の運用アドレスを用意するか。
5. **24時間対応の運用体制**: 通報・ブロック発生時にメール通知を受けた後、実際に誰が(ユーザー本人が単独運営か)、どのように(Firestore コンソールを直接操作するか、簡易管理画面を別途作るか)24時間以内に対応するかの運用フローを確定する必要がある。今回のスコープでは「通知の自動化」までとし、実際の審査/対応作業自体は人力運用とする前提でよいか。
6. **Cloudinary API Key/Secret の新規発行**: アカウント削除時の画像カスケード削除、および将来のサーバー側画像操作のために、現在クライアントにしか露出していない unsigned preset とは別に、Cloud Functions 用の signed API Key/Secret を新規発行し、Functions のシークレットとして安全に管理する必要がある。Cloudinary アカウントへのアクセス権を用意できるか。
7. **Firestore セキュリティルール**: リポジトリ内に `firestore.rules` が見当たらない。現在のルールが Firebase コンソール側でどう設定されているか(特に `blocks`/`reports`/`moderationActions` のような新規コレクションに対し、クライアントからの不正な直接書き込み・改ざんを防ぐルールを新設する必要がある)を確認したい。アクセス可能か、現状のルールを共有してもらえるか。
8. **App Store スクリーンショットのプレースホルダ差し替え(リジェクト理由4)**: これはコードではなく App Store Connect 上のアセット差し替え作業であり、本設計書のスコープ外とした。対応要否・担当を別途確認したい。
9. **既存ユーザーへの遡及対応**: すでに Firestore に存在する投稿・ユーザーには `moderationStatus`/`eulaAcceptedAt`/`isDeletionRequested` 等の新フィールドが存在しない。デフォルト値での安全な扱い(未設定=`visible`/`false`扱い)で問題ないか、それとも一括バックフィルのスクリプトを別途用意すべきか。
10. **EditProfileScreen のユーザー名変更ポリシー**: 現状 `UserService.updateUsername` に変更頻度制限がない。ユーザー名を頻繁に変えられることで通報・ブロック時の対象特定に支障が出ないか(将来的な検討事項として明記するのみで良いか、今回のスコープに含めるか)。
