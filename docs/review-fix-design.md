# App Store 審査リジェクト対応 設計ドキュメント

- 作成日: 2026-07-15
- 最終更新: 2026-07-15（要確認事項 #3 の回答を反映: EULA は Apple 標準 LAEULA を使用、ゼロトレランス条項はアプリ内利用規約に明記）
- 対象リジェクト: Guideline 1.2（UGC対策）/ 5.1.1(v)（アカウント削除）/ 2.1(a)（iPadボタン無反応）/ 2.1(a)（スクリーンショット）
- 本ドキュメントは設計のみを記述する。実装コードは含まない。

---

## 1. 現状アーキテクチャ要約

### 1.1 全体構成

| 項目 | 内容 |
|---|---|
| UI | SwiftUI（iOS 26.1+、`TARGETED_DEVICE_FAMILY = "1,2"` で iPhone/iPad 両対応） |
| アーキテクチャ | MVVM。`Views/` + `ViewModels/`（`@MainActor ObservableObject`） + `Services/`（シングルトン、`static let shared` / `private init()`） |
| 認証 | Firebase Auth（メール/パスワードのみ）。`AuthenticationService` がラッパー、`AuthViewModel` が `addStateDidChangeListener` で状態監視 |
| データ層 | Cloud Firestore（Firebase iOS SDK 12.15.0, SPM）。`FirebaseManager` がコレクション参照を一元管理 |
| 画像 | Cloudinary（unsigned upload preset: `peephole_posts` / `peephole_profiles`、cloud name `dw71feikq`）。URL変換でサムネイル生成 |
| ウィジェット | WidgetKit 拡張（`PeepholeWidgetExtension`）。App Group `group.app.takaoka.com.peephole.shared` 内の `widgetData.json` を `SharedDataManager` 経由で読み書き。Firebase 依存なし |
| その他 | App Check（DEBUG のみデバッグプロバイダ）、FirebaseFunctions / FirebaseRemoteConfig / FirebaseMessaging 等も SPM でリンク済み（未使用） |

### 1.2 Firestore コレクション（現状）

| コレクション | モデル | 主なフィールド |
|---|---|---|
| `users` | `FirestoreUser`（UserService.swift 内） | userId, username, displayName, email, profileImageURL, bio, isPrivate（現状全員 true）, followersCount, followingCount, postsCount, createdAt, updatedAt |
| `posts` | `FirestorePost`（PostService.swift 内） | postId, userId, imageURL, thumbnailURL, text, song, userName/userDisplayName/userProfileImageURL（非正規化）, createdAt, updatedAt, expiresAt, isExpired |
| `follows` | `FirestoreFollow`（FollowService.swift 内） | followId, followerId, followingId, createdAt |
| `followRequests` | `FirestoreFollowRequest`（FollowService.swift 内） | requestId, requesterId, targetId, status(pending/accepted/rejected), createdAt, respondedAt |

Firestore モデルは各 Service ファイル冒頭に `Firestore` プレフィックス付き struct として定義するのが本コードベースの規約。エラーは `XxxServiceError: LocalizedError` を各 Service に定義し、日本語の `errorDescription` を持つ。

### 1.3 画面遷移（現状）

```
RootView (PeepholeApp.swift)
├─ isInitializing → LoadingView
├─ 未認証 → WelcomeScreen (NavigationStack)
│   ├─ navigationDestination → LoginScreen
│   └─ navigationDestination → SignUpScreen
└─ 認証済み → MainTabView (TabView, 5タブ)
    ├─ tag 0: NavigationStack { HomeScreen }          … タイムライン（PostCardView のリスト）
    ├─ tag 1: NavigationStack { DiscoverPlaceholderScreen } … 「今後実装予定」のプレースホルダ
    ├─ tag 2: Color.clear → sheet で PostCreateScreen
    ├─ tag 3: NavigationStack { NotificationsScreen } … フォローリクエスト承認/拒否
    └─ tag 4: NavigationStack { ProfileScreen }
        ├─ toolbar 歯車 → sheet で SettingsView（ProfileScreen.swift 内定義。ログアウトのみ）
        └─ 「プロフィールを編集」ボタン → ★アクションが空（後述）
```

補足:
- `UserProfileScreen`（他ユーザーのプロフィール）は実装済みだが、**現状どこからも遷移していない**（発見タブが未実装のため）。
- `ContentView .swift`（ファイル名に空白あり）は開発初期の残骸で、アプリからは未参照。
- タイムライン（`HomeViewModel`）とウィジェット（`WidgetDataUpdater`）には「自分自身の投稿も表示する」動作確認用 TODO が残っている。
- ウィジェットは初回起動時に `SharedDataManager.generateMockData()`（picsum.photos / pravatar.cc のダミー画像・架空ユーザー）を保存する。

### 1.4 審査対応に関わる既存実装の状態

| 要件 | 現状 |
|---|---|
| EULA 同意 | なし（規約文書・同意 UI・同意記録すべて未実装） |
| 不適切コンテンツのフィルタリング | なし |
| 通報機能 | なし |
| ブロック機能 | なし |
| アカウント削除 | `AuthenticationService.deleteAccount()`（Auth のみ削除）と `AuthViewModel.deleteAccount()`（Firestore 削除は TODO コメント）が存在するが、**UI からの導線なし・Firestore データ削除なし・再認証処理なし** |
| プロフィール編集 | `ProfileViewModel.updateProfile()` / `updateProfileImage()` は実装済みだが、**編集画面が存在せずボタンのアクションが空** |

---

## 2. Guideline 1.2 — UGC 対策の設計

### 2.0 方針

Apple の要求 5 点（EULA / フィルタリング / 通報 / ブロック / 24時間対応）を、以下の構成で満たす。

- クライアント: 同意ゲート、通報・ブロック UI、NG ワードフィルタ、フィード/ウィジェットからの即時除外
- Firestore: `blocks` / `reports` コレクション追加、`users` に同意記録フィールド追加、`posts` に `isHidden` 追加
- バックエンド（Firebase）: Cloud Functions で通報/ブロック発生時に開発者へメール通知（24時間対応フローの起点）。Cloudinary 側で画像モデレーション（アップロードプリセット設定、コード変更なし）

すべての新規 Service は既存規約（シングルトン、`FirestoreXxx` モデル同居、`XxxServiceError`、日本語コメント + `// MARK:` 構成、絵文字付き print ログ）に従う。

### 2.1 EULA への同意（登録前提示）

#### 方針（要確認事項 #3 の回答を反映）

- **EULA は Apple 標準の Licensed Application End User License Agreement（LAEULA）をそのまま使用する。** App Store Connect でカスタム EULA は設定しない（App Store Connect 側の作業は不要）。
- **「不適切なコンテンツ・虐待的なユーザーへのゼロトレランス」条項は、アプリ内で同意を取る自前の「利用規約」に明記する**（Guideline 1.2 の明示要求はこちらで満たす）。登録前の同意ゲートはこの利用規約＋プライバシーポリシーに対して行う。
- 利用規約には「本アプリの使用許諾は Apple 標準 EULA（https://www.apple.com/legal/internet-services/itunes/dev/stdeula/）に従う」旨の条項とリンクを含める。
- 利用規約・プライバシーポリシーの文面ドラフトは T3 の実装内で作成する（一般的な文面。公開前に法務レビューを推奨する旨を T3 に注記）。

#### 新規/変更ファイル

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Views/Legal/LegalTexts.swift` | 新規 | 利用規約とプライバシーポリシーの本文（T3 でドラフト作成）を `static let` 文字列で保持。`static let currentTermsVersion: String`（例 `"1.0"`）を定義。EULA 本文は保持しない（Apple 標準 LAEULA を使用するため）。利用規約には①「不適切なコンテンツや虐待的なユーザーへのゼロトレランス（許容しない。コンテンツ削除・アカウント停止を行う）」条項、②Apple 標準 EULA に従う旨とリンク、を必ず含める |
| `Peephole/Views/Legal/TermsScreen.swift` | 新規 | 規約全文を `ScrollView` で表示する画面。`enum LegalDocumentType { case terms, privacyPolicy }` を受け取り本文を切替。閉じるボタンのみ（同意ボタンは持たない、表示専用） |
| `Peephole/Views/Auth/SignUpScreen.swift` | 変更 | 登録ボタンの上に同意チェックボックス行を追加：「[利用規約]と[プライバシーポリシー]に同意します」。リンクタップで `TermsScreen` を sheet 表示。`canSignUp` に `agreedToTerms == true` を追加（未同意時は登録ボタン無効） |
| `Peephole/Services/UserService.swift` | 変更 | `FirestoreUser` に `agreedTermsVersion: String?` / `agreedTermsAt: Date?` を追加。`createUserProfile` で同意バージョンを書き込む。`updateTermsAgreement(userId:version:)` メソッド追加（既存ユーザーの再同意用） |
| `Peephole/ViewModels/AuthViewModel.swift` | 変更 | `@Published var needsTermsAgreement: Bool` を追加。`fetchCurrentUser` 後に `agreedTermsVersion != LegalTexts.currentTermsVersion` なら true。`agreeToCurrentTerms()` メソッド追加 |
| `Peephole/PeepholeApp.swift`（RootView） | 変更 | 認証済みかつ `needsTermsAgreement == true` のとき、MainTabView の上に全画面 sheet（`interactiveDismissDisabled`）で同意画面（`TermsAgreementScreen`）を表示 |
| `Peephole/Views/Legal/TermsAgreementScreen.swift` | 新規 | 既存ユーザー向けの再同意画面。規約本文＋「同意する」ボタン。同意するまで閉じられない |

#### データモデル変更（users）

```
users/{userId}
  + agreedTermsVersion: String?   // 同意した規約バージョン（例 "1.0"）
  + agreedTermsAt: Timestamp?     // 同意日時
```

既存ドキュメントにフィールドがない場合は「未同意」として扱う（`Codable` では Optional なのでデコード互換あり）。

#### フロー

- 新規登録: SignUpScreen で同意チェックなしでは登録不可 → `createUserProfile` で同意記録を保存。**Apple の要求「登録/ログインの前に提示」はこれで満たす**（同意なしにアカウントは作成されない）。
- 既存ユーザー/規約改定時: ログイン後 RootView が `needsTermsAgreement` を検知し `TermsAgreementScreen` を強制表示 → 同意で `updateTermsAgreement` → sheet 閉鎖。

### 2.2 ブロック機能

#### 新規/変更ファイル

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Services/BlockService.swift` | 新規 | `FirestoreBlock` モデル定義。`blockUser(blockerId:blockedId:)`（トランザクションでブロック作成＋双方向のフォロー関係・保留中フォローリクエストを削除＋フォローカウント調整）、`unblockUser(blockerId:blockedId:)`、`getBlockedIds(userId:) -> [String]`、`getBlockerIds(userId:) -> [String]`、`isBlocked(between:and:) -> Bool`。`BlockServiceError` 定義 |
| `Peephole/Services/FirebaseManager.swift` | 変更 | `blocksCollection`（`db.collection("blocks")`）を追加 |
| `Peephole/Services/FollowService.swift` | 変更 | `sendFollowRequest` の冒頭でブロック関係（双方向）をチェックし、存在すれば `FollowServiceError.unknown` ではなく新設ケース `.blocked`（「このユーザーをフォローできません」）を throw |
| `Peephole/ViewModels/HomeViewModel.swift` | 変更 | `loadTimeline` / `refreshTimeline` / `loadMorePosts` で `BlockService.getBlockedIds` + `getBlockerIds` を取得し、`targetUserIds` から除外。`blockUser(userId:)` メソッド追加：ブロック実行 → `posts` から該当ユーザーの投稿を即時 `removeAll` → `WidgetDataUpdater.updateWidgetWithFollowingPosts` を再実行（**「ブロック時に即座にフィードから消える」要件**） |
| `Peephole/ViewModels/UserProfileViewModel.swift` | 変更 | `FollowStatus` に `.blocked` を追加（buttonTitle「ブロック中」/ buttonColor `.gray`）。`loadUserProfile` でブロック状態を確認し、ブロック中は投稿を読み込まない。`blockUser()` / `unblockUser()` メソッド追加 |
| `Peephole/Views/Profile/UserProfileScreen.swift` | 変更 | toolbar 右に `Menu`（`ellipsis` アイコン）を追加：「ブロックする/ブロック解除」「通報する」。ブロックは `confirmationDialog` で確認（既存 NotificationsScreen の確認ダイアログと同じパターン） |
| `Peephole/Views/Main/HomeScreen.swift`（PostCardView） | 変更 | カード右上に `Menu`（`ellipsis`）を追加。他人の投稿：「このユーザーをブロック」「この投稿を通報」。自分の投稿：「投稿を削除」。ブロック/削除は `confirmationDialog` 確認付き。コールバック（`onBlock` / `onReport` / `onDelete`）クロージャで親（HomeScreen → HomeViewModel）に委譲 |
| `Peephole/Services/WidgetDataUpdater.swift` | 変更 | `updateWidgetWithFollowingPosts` 内で `getBlockedIds` / `getBlockerIds` を取得し `targetUserIds` から除外（フォロー解除で通常は消えるが、書き込み競合への防御として明示的に除外する） |
| `Peephole/ViewModels/BlockedUsersViewModel.swift` | 新規 | ブロック中ユーザー一覧の取得（`getBlockedIds` → 各 `getUserProfile`。NotificationsViewModel の `FollowRequestWithUser` と同じ結合パターン）と解除操作 |
| `Peephole/Views/Settings/BlockedUsersScreen.swift` | 新規 | 設定画面から遷移するブロック一覧。各行に「ブロック解除」ボタン |

#### データモデル（新規コレクション blocks）

```
blocks/{blockId}
  blockId: String       // ドキュメントID（follows と同じ採番方式）
  blockerId: String     // ブロックした人
  blockedId: String     // ブロックされた人
  createdAt: Timestamp
```

`FirestoreFollow` と同型の struct を `BlockService.swift` に定義する。

#### blockUser のトランザクション内容

1. `blocks` に新規ドキュメント作成
2. `follows` から `blocker→blocked` / `blocked→blocker` の両方向を検索して削除（存在するもののみ。事前クエリはトランザクション外、削除はトランザクション内 — 既存 `unfollow` と同じ構成）
3. 削除したフォロー関係に応じて両者の `followersCount` / `followingCount` を減算
4. `followRequests` の双方向 pending リクエストを削除

#### ブロックの効果（仕様）

- ブロックした側: タイムライン・ウィジェットから対象の投稿が即時消える。対象のプロフィールでは投稿非表示。
- ブロックされた側: フォロー関係が消えるため相手の投稿が見えなくなる。フォローリクエスト送信不可（`.blocked` エラー。ただし UI 上は「ブロックされている」と明示しない文言にする）。
- 開発者通知: `blocks` ドキュメント作成を Cloud Functions トリガーで検知しメール送信（2.5 参照）。

### 2.3 通報機能

#### 新規/変更ファイル

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Services/ReportService.swift` | 新規 | `FirestoreReport` モデル・`ReportReason` enum 定義。`submitReport(reporterId:targetType:targetPostId:targetUserId:reason:detail:)`、`hidePost(userId:postId:)`（`users/{uid}/hiddenPosts/{postId}` へ書き込み）、`getHiddenPostIds(userId:) -> [String]`。`ReportServiceError` 定義 |
| `Peephole/ViewModels/ReportViewModel.swift` | 新規 | 通報フォームの状態（選択理由・詳細テキスト・送信中フラグ）と送信処理。投稿通報時は送信成功後に `hidePost` も実行 |
| `Peephole/Views/Report/ReportScreen.swift` | 新規 | sheet で表示する通報画面。理由の選択リスト（`ReportReason` 全ケース）＋任意の詳細 `TextEditor`（最大 500 文字、PostCreateViewModel と同じ prefix 切り詰め方式）＋送信ボタン。送信完了で「通報を受け付けました。24時間以内に対応します」を表示して dismiss |
| `Peephole/Views/Main/HomeScreen.swift`（PostCardView） | 変更 | 2.2 のメニューに「この投稿を通報」を追加（`onReport` コールバック）。HomeScreen 側で `ReportScreen` を sheet 表示 |
| `Peephole/Views/Profile/UserProfileScreen.swift` | 変更 | 2.2 のメニューに「通報する」（ユーザー通報、targetType = .user） |
| `Peephole/ViewModels/HomeViewModel.swift` | 変更 | タイムライン取得後に `getHiddenPostIds` の結果で `posts` をフィルタ（通報者の画面から通報済み投稿を即時・永続的に非表示）。通報直後は `posts.removeAll { $0.postId == reportedId }` でローカル即時反映 |
| `Peephole/Services/WidgetDataUpdater.swift` | 変更 | `hiddenPostIds` を取得してウィジェット投稿からも除外 |

#### データモデル（新規）

```
reports/{reportId}
  reportId: String
  reporterId: String                 // 通報者
  targetType: String                 // "post" | "user"
  targetPostId: String?              // targetType == "post" のとき必須
  targetUserId: String               // 投稿通報でも投稿者のIDを常に保持（対応を容易にする）
  reason: String                     // ReportReason の rawValue
  detail: String?                    // 任意の補足（最大500文字）
  status: String                     // "pending" | "reviewed" | "actioned"（作成時は "pending"）
  createdAt: Timestamp

users/{userId}/hiddenPosts/{postId}  // 通報者ローカルの非表示リスト（端末をまたいで有効）
  postId: String
  hiddenAt: Timestamp
```

```
ReportReason（enum, String, CaseIterable, Codable）
  case inappropriateContent  // 不適切なコンテンツ（性的・暴力的など）
  case harassment            // 嫌がらせ・いじめ
  case spam                  // スパム
  case impersonation         // なりすまし
  case other                 // その他
  // displayName: String を持たせ日本語表示（既存 FollowStatus.buttonTitle と同じパターン）
```

### 2.4 不適切コンテンツのフィルタリング

二層で構成する。

#### (a) テキスト: クライアント側 NG ワードフィルタ

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Services/ModerationService.swift` | 新規 | シングルトン。バンドル内 `ProhibitedWords.json`（`["word1", "word2", ...]` 形式）を読み込み、`containsProhibitedWord(_ text: String) -> Bool`（大文字小文字無視・空白除去して部分一致）を提供。将来 Firebase Remote Config で語彙を上書き取得できる構造にする（初期実装はバンドル JSON のみで可） |
| `Peephole/Resources/ProhibitedWords.json` | 新規 | NG ワードリスト（日本語・英語の卑語/差別語/暴力表現の初期セット） |
| `Peephole/ViewModels/PostCreateViewModel.swift` | 変更 | `createPost` のバリデーションに NG ワードチェックを追加。ヒット時は `showErrorMessage("不適切な表現が含まれているため投稿できません")` で中断 |
| `Peephole/ViewModels/ProfileViewModel.swift` | 変更 | `updateProfile` 前に displayName / bio に同チェック |

#### (b) 画像: Cloudinary モデレーション（バックエンド設定 + posts.isHidden）

- Cloudinary の upload preset `peephole_posts` に moderation（AWS Rekognition アドオン等）を設定（**Cloudinary コンソールでの設定作業。アプリコード変更なし**）。
- モデレーション結果 rejected の Webhook を Cloud Functions（HTTPS 関数）で受け、該当 `posts` ドキュメントの `isHidden` を true に更新。
- `FirestorePost` に `isHidden: Bool` を追加し、`getUserPosts` / `getTimelinePosts` のクエリに `whereField("isHidden", isEqualTo: false)` を追加。

```
posts/{postId}
  + isHidden: Bool   // モデレーション/運営対応で非表示。デフォルト false
```

注意点:
- 既存の posts ドキュメントには `isHidden` が存在しないため、**クエリ条件に含めると既存投稿がヒットしなくなる**。対応方針: `FirestorePost` のデコードは `isHidden` を非 Optional で持ちつつ、リリース前に既存全ドキュメントへ `isHidden: false` をバックフィルする（一括更新スクリプトまたは手動。件数は開発データのみのはずなので少ない — 要確認事項 #8）。
- 複合インデックス追加が必要: `posts` に対し `(userId, isExpired, isHidden, createdAt desc)` 相当。Firestore コンソールのエラーリンクから作成する。
- 運営（開発者）が通報対応で投稿を非表示にする手段としても `isHidden` を使う（Firebase コンソールから手動更新）。

### 2.5 24時間以内の対応フロー + 開発者通知

| 成果物 | 種別 | 責務 |
|---|---|---|
| `functions/`（新規ディレクトリ、Node.js Cloud Functions） | 新規 | ① `onReportCreated`: `reports/{id}` onCreate → 開発者宛メール送信（通報内容・対象投稿/ユーザーへの Firebase コンソールリンク付き）。② `onBlockCreated`: `blocks/{id}` onCreate → 同様にメール通知（**「ブロック時に開発者に通知」要件**）。③ （2.4(b)を採用する場合）Cloudinary Webhook 受け口。メール送信は Firebase Extensions「Trigger Email」(Firestore の `mail` コレクション書き込み) を採用し、Functions は `mail` へのドキュメント作成のみ行う |
| `docs/moderation-runbook.md` | 新規 | 運用手順書: 通知メール受信 → Firebase コンソールで対象確認 → 対応（`posts.isHidden = true` / 投稿削除 / `users` の当該ユーザー対応）→ `reports.status` を "actioned" に更新、を **24時間以内** に行う手順。App Review への回答文にもこのフローを記載する |

Cloud Functions は Blaze プラン（従量課金）が必要（要確認事項 #1）。Blaze 化が不可の場合の代替案: 通報/ブロックを Firestore に加えて Google フォーム的な外部通知はセキュリティ上不可のため、**Firebase コンソールの Firestore 画面を毎日確認する運用 + App Review 回答でその旨を説明**に格下げする（審査上はメール通知ありが望ましい）。

### 2.6 設定画面の基盤整備（ブロック一覧・アカウント削除の置き場所）

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Views/Settings/SettingsScreen.swift` | 新規 | 現在 `ProfileScreen.swift` 内にある `SettingsView`（ログアウトのみ）を独立ファイルに移設し `SettingsScreen` に改名（画面は `XxxScreen` 命名規約に合わせる）。セクション構成: 「アカウント」（ブロックしたユーザー → BlockedUsersScreen / アカウントを削除 → AccountDeleteScreen）、「情報」（利用規約 / プライバシーポリシー → TermsScreen）、「セッション」（ログアウト） |
| `Peephole/Views/Profile/ProfileScreen.swift` | 変更 | `SettingsView` struct を削除し、sheet の中身を `NavigationStack { SettingsScreen() }` に差し替え（画面内遷移があるため NavigationStack で包む） |

---

## 3. Guideline 5.1.1(v) — アカウント削除の設計

### 3.1 要件

- アプリ内から削除を**開始**でき、アカウントとユーザーデータが実際に削除されること（無効化・非表示化は不可）。
- Firebase Auth の `user.delete()` は直近ログインを要求するため（`requiresRecentLogin` エラー）、**パスワード再入力による再認証**をフローに組み込む。

### 3.2 新規/変更ファイル

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Services/AuthenticationService.swift` | 変更 | `reauthenticate(password:)` を追加（`EmailAuthProvider.credential` + `user.reauthenticate`）。`AuthError` に `.requiresRecentLogin`（「セキュリティのため再ログインが必要です」）を追加し `mapAuthError` に対応ケースを追加 |
| `Peephole/Services/UserService.swift` | 変更 | `deleteUserData(userId:)` を追加。削除順序は 3.3 参照。バッチ/ループ削除で Firestore 上の当該ユーザー由来データを消す |
| `Peephole/ViewModels/AuthViewModel.swift` | 変更 | `deleteAccount(password:)` を完成させる: ①`reauthenticate` → ②`userService.deleteUserData` → ③`authService.deleteAccount()` → ④`SharedDataManager.clearWidgetData()`。成功すると auth state listener が発火し RootView が自動的に WelcomeScreen へ戻る（既存機構をそのまま利用） |
| `Peephole/Views/Settings/AccountDeleteScreen.swift` | 新規 | 削除の影響説明（投稿・フォロー関係・プロフィールが完全に削除され復元不可）→ パスワード入力（`SecureField`、LoginScreen と同スタイル）→ 「アカウントを削除」ボタン（`role: .destructive` + `confirmationDialog` で最終確認）→ 進行中は `ProgressView` |
| `Peephole/Views/Settings/SettingsScreen.swift` | 変更 | 「アカウントを削除」行（赤字）から `NavigationLink` で AccountDeleteScreen へ |
| `Peephole/Shared/SharedDataManager.swift` | 変更 | `clearWidgetData()` を追加（`widgetData.json` を削除し `reloadWidget()`）。ログアウト時にも呼ぶ（他人のデータがウィジェットに残る問題の解消。`AuthViewModel.logout()` から呼び出し） |

### 3.3 データ削除の順序と内容（`UserService.deleteUserData`）

Auth アカウント削除**前**に Firestore を消す（削除後はセキュリティルール上書き込めなくなるため）。

1. `posts`: `userId == 自分` を全件取得 → 削除（500 件ずつの WriteBatch）
2. `follows`: `followerId == 自分` を全件取得 → 各相手の `followersCount` を -1 → 削除
3. `follows`: `followingId == 自分` を全件取得 → 各相手の `followingCount` を -1 → 削除
4. `followRequests`: `requesterId == 自分` / `targetId == 自分` を削除
5. `blocks`: `blockerId == 自分` / `blockedId == 自分` を削除
6. `users/{uid}/hiddenPosts` サブコレクションを削除
7. `users/{uid}` 本体を削除
8. `reports` は**削除しない**（モデレーション記録として保持。通報者IDが消えたユーザーを指す場合があるが許容）

補足:
- Cloudinary 上の画像削除は unsigned API では不可能（Admin API は api_secret 必須でクライアントに置けない）。初期対応では**画像はオーファンとして残す**か、Cloud Functions（Auth onDelete トリガー）で Cloudinary Admin API を呼んで削除する（要確認事項 #6）。
- 途中失敗時の挙動: Firestore 削除が部分的に完了し Auth 削除前にエラーになった場合、ユーザーは再度削除を実行できる（各ステップは冪等）。設計上これを許容する。

### 3.4 画面遷移

```
ProfileScreen → (歯車) → SettingsScreen
  → アカウントを削除 → AccountDeleteScreen
    → パスワード入力 → confirmationDialog「本当に削除しますか？この操作は取り消せません」
    → 削除実行（ProgressView）→ 成功 → auth listener 経由で WelcomeScreen に自動遷移
    → 失敗（パスワード誤り等）→ 既存パターンの alert 表示
```

---

## 4. Guideline 2.1(a) — iPad「プロフィールを編集」無反応の設計

### 4.1 原因仮説と検証方法

**仮説 A（コードリーディングにより事実確認済み・確度: ほぼ確定）**
`ProfileScreen.swift:36-38` の「プロフィールを編集」ボタンはアクションクロージャが空（`// 将来的な実装: EditProfileScreenへ遷移` コメントのみ）。**iPad 固有ではなく全デバイスで無反応**であり、審査員が iPad でテストしたため iPad の問題として報告されたと考えられる。
- 検証方法: ①該当コードの目視（済み。アクションは空）。②iPhone / iPad 両シミュレータで当該ボタンをタップし、いずれでも何も起きないことを確認する。③アクション内に `print` を仮置きしてタップイベント自体は届いていること（＝ハングやヒットテスト不良ではないこと）を確認する。

**仮説 B（対応後の再発防止として検証。確度: 低）**
編集画面を sheet 遷移で実装した後、iPadOS 26.x の `TabView` + `NavigationStack` + `sheet` の組み合わせで表示不良が起きる可能性。
- 検証方法: iPad Air 11-inch (M3) / iPadOS 26.x シミュレータで、①ProfileScreen からの sheet 表示、②回転（縦横）、③Split View / Stage Manager 環境下での表示、をそれぞれ確認する。

**仮説 C（確度: 低）**
`ScrollView` 内でボタンが全幅に伸びており、iPad の広い画面で別ビュー（透明オーバーレイ等）がタップを奪っている可能性。
- 検証方法: Xcode View Debugger（Debug View Hierarchy）でボタン上に重なるビューがないか確認。`allowsHitTesting` の影響を受けるビューがないかコード確認。

**仮説 D（確度: 低）**
`AsyncImage` のプレースホルダや `refreshable` のジェスチャ競合により、タップが `ScrollView` のジェスチャとして解釈される可能性。
- 検証方法: 実機/シミュレータでタップとスクロールを織り交ぜ、タップ成功率を確認。問題があれば `Button` に `.buttonStyle(.plain)` 等を検討。

結論: **根本原因は仮説 A（未実装）**。修正は「編集画面を実装して遷移を実装する」こと。B〜D は実装後の iPad 検証チェックリストとして消化する。

### 4.2 修正設計（EditProfileScreen の新規実装）

| ファイル | 種別 | 責務 |
|---|---|---|
| `Peephole/Views/Profile/EditProfileScreen.swift` | 新規 | sheet で表示するプロフィール編集画面。`NavigationStack` 内に: ①プロフィール画像（現在画像を表示、タップで `PhotosPicker` — PostCreateScreen と同じ実装パターン）、②表示名 `TextField`、③自己紹介 `TextEditor`（最大 150 文字、PostCreateViewModel と同じ prefix 切り詰め）。toolbar: 「キャンセル」（leading）/「保存」（trailing、変更がない場合は disabled）。保存中は ProgressView。既存の `ProfileViewModel` を `@ObservedObject` で受け取り、`updateProfile(displayName:bio:)` / `updateProfileImage(_:)` を呼ぶ（**ViewModel の新設は不要**。ロジックは実装済み） |
| `Peephole/Views/Profile/ProfileScreen.swift` | 変更 | `@State private var showEditProfile = false` を追加。「プロフィールを編集」ボタンのアクションを `showEditProfile = true` に。`.sheet(isPresented: $showEditProfile) { EditProfileScreen(viewModel: viewModel) }` を追加。保存成功後は `viewModel.loadProfile` が既に再読み込みするため追加処理不要（`authViewModel.refreshCurrentUser()` も呼び、非正規化データの元となる currentUser を更新） |

補足: username（@名）の変更は `UserService.updateUsername` が既にあるが、投稿の非正規化フィールド（userName 等）との整合を取る仕組みがないため、**初期対応では編集対象を displayName / bio / プロフィール画像に限定**する（要確認事項 #7）。

---

## 5. Guideline 2.1(a) — スクリーンショットのプレースホルダ（参考）

これは App Store Connect のメタデータ修正が主対応（コード外）だが、コード側にも関連リスクがあるため以下を推奨タスクに含める。

- **ウィジェットのモックデータ**: `PeepholeApp.setupMockDataIfNeeded()` と `SharedDataManager.generateMockData()` は本番でも架空ユーザー（picsum.photos / pravatar.cc）を表示する。実データのスクリーンショット撮影の妨げになり、審査員にプレースホルダと見なされるリスクがある → モック初期化を `#if DEBUG` に限定し、本番の空状態は `EmptyWidgetView`（実装済み）に任せる。
- **発見タブ**: 「ユーザー検索機能は今後実装予定です」というプレースホルダ画面は Guideline 2.1/2.2（未完成アプリ）の再指摘リスク → 審査提出版ではタブ自体を非表示にする（`MainTabView` から発見タブを削除。タブ tag の再割当てに注意: 投稿=2 のハンドリングを維持するか tag を詰める）。
- スクリーンショットは実機（iPhone / 13" iPad 必須サイズ）で実データを用いて再撮影する（運用作業）。

---

## 6. 実装順序（タスクリスト）

各タスクは 1 コミット相当。依存関係順に並べてある。**「完了条件」をすべて満たすこと**をコミットの条件とする。共通完了条件として全タスクで「アプリターゲットと Widget ターゲットのビルドが通ること」を含む。

### フェーズ 1: バグ修正（Guideline 2.1）

**T1. EditProfileScreen の実装と「プロフィールを編集」ボタンの接続**
- 内容: §4.2 の通り。`EditProfileScreen.swift` 新規、`ProfileScreen.swift` 変更。
- 完了条件:
  - iPhone / iPad シミュレータの両方で「プロフィールを編集」タップ → 編集画面が sheet 表示される。
  - 表示名・自己紹介を変更して保存 → Firestore の `users/{uid}` の `displayName` / `bio` / `updatedAt` が更新され、ProfileScreen の表示が保存後に反映される。
  - プロフィール画像を PhotosPicker から選択して保存 → Cloudinary にアップロードされ `profileImageURL` が更新される。
  - 変更なしの状態では「保存」が disabled。保存中は多重タップ不可。
  - 自己紹介が 150 文字で切り詰められる。

### フェーズ 2: 設定基盤

**T2. SettingsScreen の独立と設定画面骨格**
- 内容: §2.6。`SettingsView` を `Views/Settings/SettingsScreen.swift` に移設・改名し、セクション骨格（アカウント/情報/セッション）を作る。未実装遷移先の行はこの時点では置かない（後続タスクで追加）。
- 完了条件:
  - `ProfileScreen.swift` から `SettingsView` struct が消え、歯車 → 設定 sheet が `SettingsScreen` で表示される。
  - ログアウトが従来通り動作する（タップ → WelcomeScreen へ戻る）。
  - `grep -r "SettingsView" Peephole/` が 0 件。

### フェーズ 3: EULA（Guideline 1.2-①）

**T3. 規約文書と表示画面（LegalTexts / TermsScreen）**
- 内容: §2.1。利用規約・プライバシーポリシーの文面ドラフトを作成し（一般的な文面。ファイル冒頭コメントに「公開前に法務レビュー推奨」と注記）、`LegalTexts.swift`（本文と `currentTermsVersion = "1.0"`）、`TermsScreen.swift` を実装。SettingsScreen「情報」セクションに「利用規約」「プライバシーポリシー」行を追加し遷移。EULA は Apple 標準 LAEULA を使用するため、アプリ内に EULA 本文は持たず App Store Connect 側の設定変更も行わない。
- 完了条件:
  - 設定 → 利用規約 / プライバシーポリシーで全文がスクロール表示される。
  - 利用規約本文に「不適切なコンテンツ・虐待的なユーザーを許容しない（アカウント停止・コンテンツ削除を行う）」旨の条項が含まれる。
  - 利用規約本文に「本アプリの使用許諾は Apple 標準 EULA に従う」旨の記載と `https://www.apple.com/legal/internet-services/itunes/dev/stdeula/` の URL が含まれる。
  - プライバシーポリシーに、収集するデータ（メールアドレス、ユーザー名、投稿内容・画像）、利用目的、第三者サービス（Firebase / Cloudinary）への保存、削除方法（アプリ内アカウント削除）の記載が含まれる。
  - `LegalTexts.currentTermsVersion` が定義されている。

**T4. 新規登録時の同意ゲートと同意記録**
- 内容: §2.1。SignUpScreen に同意チェック＋規約リンク、`FirestoreUser` にフィールド追加、`createUserProfile` で記録。
- 完了条件:
  - 同意チェックが OFF の間、他の入力が揃っていても「登録」ボタンが disabled。
  - チェック行の「利用規約」「プライバシーポリシー」リンクタップで TermsScreen が sheet 表示される。
  - 新規登録後、Firestore の `users/{uid}` に `agreedTermsVersion: "1.0"` と `agreedTermsAt` が保存されている。
  - 既存フィールドのみの users ドキュメントが `FirestoreUser` としてデコードエラーにならない（Optional 定義）。

**T5. 既存ユーザーの再同意フロー**
- 内容: §2.1。`TermsAgreementScreen.swift` 新規、`AuthViewModel.needsTermsAgreement` / `agreeToCurrentTerms()`、RootView での強制表示。
- 完了条件:
  - `agreedTermsVersion` が nil または `currentTermsVersion` と不一致のユーザーでログイン → MainTabView 表示直後に同意画面が全画面 sheet で表示され、スワイプで閉じられない。
  - 「同意する」タップで Firestore に同意記録が保存され、sheet が閉じ、以後の起動では表示されない。
  - 同意済みユーザーには表示されない。

### フェーズ 4: ブロック（Guideline 1.2-④）

**T6. BlockService とデータ層**
- 内容: §2.2。`BlockService.swift` 新規（モデル・blockUser/unblockUser/getBlockedIds/getBlockerIds/isBlocked）、`FirebaseManager.blocksCollection` 追加。
- 完了条件:
  - `blockUser` 実行で `blocks` ドキュメントが作成され、双方向の `follows` と pending `followRequests` が削除され、関係者のフォローカウントが正しく減算される（フォロー関係がないペアでもエラーにならない）。
  - 同一ペアの二重ブロックは `BlockServiceError.alreadyBlocked` を throw。
  - `unblockUser` で `blocks` ドキュメントが削除される（フォロー関係は復元しない）。
  - 既存の `FollowServiceTests` と同様のスタイルで `BlockServiceTests.swift` を追加し、上記が XCTest で確認できる。

**T7. フォロー・タイムライン・ウィジェットへのブロック反映**
- 内容: §2.2。`FollowService.sendFollowRequest` のブロックチェック（`.blocked` エラーケース追加）、`HomeViewModel` の blockedIds/blockerIds 除外、`WidgetDataUpdater` の除外。
- 完了条件:
  - ブロック関係のあるユーザーへ `sendFollowRequest` → `FollowServiceError.blocked` が throw される（双方向）。
  - ブロック済みユーザーの投稿がタイムライン初回読み込み・リフレッシュ・追加読み込みのいずれにも現れない。
  - ウィジェット用データ（`widgetData.json`）にブロック済みユーザーの投稿が含まれない。

**T8. UserProfileScreen のブロック UI**
- 内容: §2.2。toolbar Menu（ブロック/解除・通報の項目枠。通報アクションは T12 で接続するためこの時点では項目非表示で可）、`UserProfileViewModel` の `.blocked` 状態と `blockUser()` / `unblockUser()`。
- 完了条件:
  - 他ユーザーのプロフィールで Menu →「ブロックする」→ confirmationDialog → 実行で、フォロー状態表示が「ブロック中」になり投稿グリッドが非表示になる。
  - ブロック中のプロフィールで「ブロック解除」ができ、状態が「フォローする」に戻る。
  - ブロック実行後にタイムラインへ戻る（再読み込みする）と対象の投稿が消えている。

**T9. タイムラインカードのメニューとブロック導線**
- 内容: §2.2。`PostCardView` に Menu（他人の投稿: ブロック/通報 ※通報は T12 で接続、自分の投稿: 削除）、`HomeViewModel.blockUser(userId:)`（即時除去＋ウィジェット更新）。
- 完了条件:
  - タイムラインのカードから「このユーザーをブロック」→ 確認 → 実行で、**リフレッシュ操作なしに**該当ユーザーの投稿が一覧から即時消える。
  - ブロック実行後、ウィジェット用データが更新され該当ユーザーの投稿が含まれない。
  - 自分の投稿のメニューには「投稿を削除」のみ表示され、実行で投稿が消える（既存 `deletePost` を接続）。

**T10. ブロック一覧画面**
- 内容: §2.2。`BlockedUsersViewModel.swift` / `BlockedUsersScreen.swift` 新規、SettingsScreen に「ブロックしたユーザー」行を追加。
- 完了条件:
  - 設定 → ブロックしたユーザー で、ブロック中の全ユーザーが表示名・@username・プロフィール画像付きで一覧表示される。
  - 各行の「ブロック解除」→ 確認 → 実行で一覧から消え、`blocks` ドキュメントが削除される。
  - 0 件時は空状態表示（既存 EmptyNotificationsView と同パターン）。

### フェーズ 5: 通報（Guideline 1.2-③）

**T11. ReportService とデータ層**
- 内容: §2.3。`ReportService.swift` 新規（`FirestoreReport` / `ReportReason` / submitReport / hidePost / getHiddenPostIds）。
- 完了条件:
  - `submitReport` で `reports` ドキュメントが §2.3 のスキーマ通り（status="pending"）作成される。
  - `hidePost` で `users/{uid}/hiddenPosts/{postId}` が作成され、`getHiddenPostIds` がそれを返す。
  - `BlockServiceTests` と同様のスタイルの `ReportServiceTests.swift` で上記が確認できる。

**T12. 通報 UI と非表示反映**
- 内容: §2.3。`ReportScreen.swift` / `ReportViewModel.swift` 新規。PostCardView メニュー「この投稿を通報」・UserProfileScreen メニュー「通報する」を接続。HomeViewModel / WidgetDataUpdater の hiddenPostIds フィルタ。
- 完了条件:
  - 投稿カードのメニュー → 通報 → 理由選択 → 送信で `reports` が作成され、完了メッセージ表示後 sheet が閉じる。
  - 通報した投稿が**リフレッシュ操作なしに**タイムラインから即時消え、アプリ再起動後も表示されない。
  - ウィジェット用データからも通報済み投稿が除外される。
  - UserProfileScreen から targetType="user" の通報が送信できる。
  - 理由未選択では送信ボタンが disabled。詳細テキストは 500 文字で切り詰め。

### フェーズ 6: フィルタリング（Guideline 1.2-②）

**T13. テキスト NG ワードフィルタ**
- 内容: §2.4(a)。`ModerationService.swift` / `ProhibitedWords.json` 新規、PostCreateViewModel / ProfileViewModel での検証。
- 完了条件:
  - NG ワードを含むテキストで投稿 → 投稿されず「不適切な表現が含まれているため投稿できません」の alert が出る（Cloudinary へのアップロードも行われない＝検証はアップロード前）。
  - 表示名・自己紹介に NG ワードを含めて保存 → 保存されずエラー表示。
  - 大文字小文字違い・前後空白付きでも検出される。
  - 通常テキストの投稿は従来通り成功する。

**T14. posts.isHidden の導入とクエリ反映**
- 内容: §2.4(b) のクライアント側。`FirestorePost` に `isHidden` 追加、`createPost` で false 書き込み、`getUserPosts` / `getTimelinePosts` に `whereField("isHidden", isEqualTo: false)` 追加。
- 完了条件:
  - 新規投稿の Firestore ドキュメントに `isHidden: false` が含まれる。
  - Firebase コンソールで任意の投稿を `isHidden: true` に変更 → タイムライン・プロフィール・ウィジェットのすべてから消える。
  - 必要な複合インデックスが作成済みで、クエリが index エラーにならない。
  - 既存投稿（`isHidden` フィールドなし）の扱いについてバックフィル実施（要確認事項 #8 の回答に従う）。

### フェーズ 7: アカウント削除（Guideline 5.1.1(v)）

**T15. 削除のサービス層（再認証 + カスケード削除）**
- 内容: §3.2/3.3。`AuthenticationService.reauthenticate` + `.requiresRecentLogin`、`UserService.deleteUserData`、`AuthViewModel.deleteAccount(password:)` 完成、`SharedDataManager.clearWidgetData()`（logout 時にも呼ぶ）。
- 完了条件:
  - テストユーザーで `deleteAccount(password:)` 実行後、Firestore に当該ユーザーの `users` / `posts` / `follows`（双方向）/ `followRequests` / `blocks` / `hiddenPosts` が残っていない。
  - フォロー関係のあった相手ユーザーの followersCount / followingCount が正しく減算されている。
  - Firebase Auth コンソールから当該アカウントが消えている。
  - 誤ったパスワードでは削除が実行されず、日本語のエラーメッセージが返る。
  - `widgetData.json` が削除され、ログアウト時にも削除される。

**T16. アカウント削除 UI**
- 内容: §3.2/3.4。`AccountDeleteScreen.swift` 新規、SettingsScreen に赤字の「アカウントを削除」行。
- 完了条件:
  - 設定 → アカウントを削除 → 説明文表示 → パスワード入力 → 削除ボタン → confirmationDialog（「削除する」は `role: .destructive`）→ 実行、のフローが動作する。
  - 削除完了後、自動的に WelcomeScreen へ遷移する。
  - パスワード未入力では削除ボタンが disabled。削除中は ProgressView が出て操作不可。
  - パスワード誤りでは alert が表示され画面に留まる。

### フェーズ 8: バックエンド・仕上げ

**T17. Cloud Functions による開発者通知（要確認事項 #1 の回答後に着手）**
- 内容: §2.5。`functions/` ディレクトリ新規（onReportCreated / onBlockCreated → Trigger Email 用 `mail` コレクション書き込み）、Firebase Extensions「Trigger Email」導入、`docs/moderation-runbook.md` 作成。
- 完了条件:
  - 通報作成時・ブロック作成時に、指定メールアドレスへ対象情報（reportId/blockId、対象ユーザーID、理由、コンソールリンク）を含むメールが届く。
  - `firebase deploy --only functions` が成功する。
  - runbook に 24 時間以内の対応手順（確認 → 措置 → status 更新）が記載されている。

**T18. Firestore セキュリティルールの更新（要確認事項 #4 の回答後に着手）**
- 内容: 新コレクションのルール追加。`blocks`: 作成は `request.auth.uid == blockerId` のみ・読み取りは当事者のみ・削除は blocker のみ。`reports`: 作成は `request.auth.uid == reporterId` のみ・クライアントからの読み取り/更新/削除は不可。`users/{uid}/hiddenPosts`: 本人のみ読み書き。`users` の同意フィールド更新は本人のみ。削除フロー（T15）の削除操作が許可されることも確認。
- 完了条件:
  - ルールをデプロイした状態で T6〜T16 の完了条件がすべて成立する（権限エラーが起きない）。
  - 他人になりすました block/report 作成、他人の reports 読み取りが拒否される（Firebase Emulator またはルールユニットテストで確認）。

**T19. プレースホルダ整理（Guideline 2.1(a) スクリーンショット関連の再発防止）**
- 内容: §5。ウィジェットのモック初期化（`setupMockDataIfNeeded` / Provider のモックフォールバック）を `#if DEBUG` 限定にし、リリースビルドの空状態は `EmptyWidgetView` に委ねる。発見タブを MainTabView から削除（投稿タブの tag ハンドリングを維持）。未使用の `ContentView .swift` を削除。
- 完了条件:
  - Release 構成のビルドで、投稿ゼロのウィジェットに架空ユーザーが表示されず空状態表示になる。
  - タブが「ホーム / 投稿 / 通知 / プロフィール」の 4 つになり、投稿タブのモーダル表示が従来通り動く。
  - `ContentView .swift` 削除後もビルドが通る。
  - ※App Store Connect のスクリーンショット再撮影・差し替えはコード外の運用作業として別途実施。

### 依存関係まとめ

```
T1（独立・最優先）
T2 ─┬─ T3 → T4 → T5
    ├─ T10, T16
T6 → T7 → T8, T9
T6 → T10
T11 → T12（T9 のメニュー実装に依存）
T13（独立）
T14（独立。T12 のウィジェット反映と隣接）
T15 → T16
T6, T11 → T17
T4〜T16 → T18（ルールは全機能確定後）
T19（独立・提出直前で可）
```

---

## 7. 要確認事項

### 7.1 回答済み（設計へ反映済み）

3. **規約文面の用意** — 回答: ドラフト作成はこちらで行う。EULA は Apple 標準の Licensed Application End User License Agreement（LAEULA）を使用し、「不適切コンテンツへのゼロトレランス」の文言はアプリ内利用規約に別途明記する。
   → §2.1 の方針および T3 に反映済み。アプリ内静的テキストとして実装し、App Store Connect 側の EULA 設定は変更しない。

### 7.2 未回答（回答待ち）

以下は回答待ち。**1・2・4 は該当タスク（T17 / T18）の着手に回答が必須**。5〜10 は未回答の場合、各項目に記載した「デフォルト方針」で実装を進める。

1. **Firebase の料金プラン**（T17 の前提・回答必須）: 現在 Spark（無料）か Blaze（従量課金）か、Blaze 化を承認するか。Cloud Functions による開発者通知（T17）と Cloudinary Webhook 受け口には Blaze が必要。Blaze 化できない場合、通知は「Firestore コンソールの定期確認運用」に格下げする設計に変える。
2. **開発者通知の宛先**（T17 の前提・回答必須）: 通報・ブロック通知を受け取るメールアドレス（App Review 回答にも「24時間以内対応」の連絡先として記載する）。
4. **Firestore セキュリティルールの現状**（T18 の前提・回答必須）: リポジトリにルールファイルがないため、現在コンソールで管理しているルールの内容の共有が必要（テストモードの全許可のままなら、T18 は審査再提出前に必須）。
5. **Cloudinary の画像モデレーション**: 契約プランで AWS Rekognition モデレーションアドオンが使えるか。
   デフォルト方針: 使えない前提とし、画像フィルタリングは「通報 + 24時間以内の人的対応（isHidden 化）」を審査回答の主軸にする（T14 はこの場合も必要）。
6. **アカウント削除時の Cloudinary 画像**: 投稿画像・プロフィール画像を Cloudinary からも消すか（Cloud Functions + Admin API が必要）。
   デフォルト方針: 初期リリースでは Firestore 参照のみ削除し、画像はオーファンとして残す。
7. **プロフィール編集の範囲**: username 変更を編集対象に含めるか（投稿の非正規化フィールドとの整合処理が別途必要になる）。
   デフォルト方針: T1 では displayName / bio / プロフィール画像のみ編集可とし、username 変更は対象外。
8. **既存データのバックフィル**: 本番 Firestore の既存 `posts` に `isHidden: false` を一括付与する必要がある（T14）。現在の投稿件数の確認。
   デフォルト方針: コンソール手動対応（件数が多い場合はスクリプトを用意する）。
9. **発見タブの扱い**: 審査提出版で発見タブを非表示にするか。なお `UserProfileScreen`（他ユーザープロフィール）への導線が現状存在しないため、ブロック・通報 UI の主要導線はタイムラインカードのメニューになる。
   デフォルト方針: T19 の通り非表示にする。
10. **iPad 実機検証**: iPad Air 11-inch (M3) / iPadOS 26.x の実機またはシミュレータでの最終確認を提出前チェックリストに含める。手元の Xcode で該当 OS バージョンのシミュレータが利用可能かの確認。
