# App Store 審査リジェクト対応 設計ドキュメント

- 作成日: 2026-07-15
- 最終更新: 2026-07-15（要確認事項 #3 の回答を反映: EULA は Apple 標準 LAEULA を使用、ゼロトレランス条項はアプリ内利用規約に明記）
- 最終更新: 2026-07-15（要確認事項 #1/#2/#4 の回答を反映: **Blaze 非承認前提**で開発者通知とアカウント削除を再設計、Firestore セキュリティルール設計を §6 に追加（脆弱性 A の修正を含む）、Blaze の推奨判断と費用試算を §7 に追加。旧 §6/§7 は §8/§9 に繰り下げ）
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
- バックエンド: **Blaze プランは使用しない（要確認事項 #1 の回答）**。Cloud Functions の代わりに、開発者通知は GitHub Actions の定期実行スクリプトで実現する（§2.5）。画像の自動モデレーションは初回リリースでは見送り、「テキスト NG ワード + 通報 + 24時間以内の人的対応」を主軸にする（§2.4）

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
blocks/{blockId}        // ドキュメントID = "{blockerId}_{blockedId}"（複合ID）
  blockId: String
  blockerId: String     // ブロックした人
  blockedId: String     // ブロックされた人
  createdAt: Timestamp
  notified: Bool        // 開発者通知済みフラグ（作成時 false、通知スクリプトが Admin SDK で true に更新）
```

struct は `BlockService.swift` に定義する。ドキュメント ID を複合 ID にする理由: ①同一ペアの二重ブロックが ID 衝突として自然に防げる、②セキュリティルールから `exists()` でブロック関係を検証できる（§6.3）、③クライアントが ID 直指定の `getDocument` で低コストに存在確認できる。

#### blockUser のトランザクション内容

1. `blocks` に複合 ID（`{blockerId}_{blockedId}`）で新規ドキュメント作成（`notified: false` を含む）
2. `follows` から `blocker→blocked` / `blocked→blocker` の両方向を検索して削除（存在するもののみ。事前クエリはトランザクション外、削除はトランザクション内 — 既存 `unfollow` と同じ構成）
3. 削除したフォロー関係に応じて両者の `followersCount` / `followingCount` を減算
4. `followRequests` の双方向 pending リクエストを削除

#### ブロックの効果（仕様）

- ブロックした側: タイムライン・ウィジェットから対象の投稿が即時消える。対象のプロフィールでは投稿非表示。
- ブロックされた側: フォロー関係が消えるため相手の投稿が見えなくなる。フォローリクエスト送信不可（`.blocked` エラー。ただし UI 上は「ブロックされている」と明示しない文言にする）。
- 開発者通知: `blocks` の未通知ドキュメント（`notified == false`）を GitHub Actions の定期スクリプトが検知しメール送信（§2.5 参照）。
- フォローリクエスト一覧の防御: `NotificationsViewModel.loadFollowRequests` で、自分がブロックしたユーザーからの pending リクエストを除外して表示する（ブロック前に送信済みだったリクエストへの対処）。

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
  notified: Bool                     // 開発者通知済みフラグ（作成時 false、通知スクリプトが Admin SDK で true に更新）
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

#### (b) 画像: 運営非表示フラグ posts.isHidden（自動モデレーションは見送り）

- **Blaze 非承認（要確認事項 #1）により Webhook 受け口（Cloud Functions HTTPS 関数）を持てないため、画像の自動モデレーションは初回リリースでは見送りで確定**。画像への対策は「通報 + 24時間以内の人的対応（isHidden 化 / 削除）」で担保し、App Review への回答でもその運用を説明する。
- 補助運用（任意・コード変更なし）: Cloudinary の upload preset `peephole_posts` に手動モデレーション（moderation=manual）を設定すると、Cloudinary コンソールのモデレーションキューで新着画像を目視確認できる。
- `FirestorePost` に `isHidden: Bool` を追加し、`getUserPosts` / `getTimelinePosts` のクエリに `whereField("isHidden", isEqualTo: false)` を追加。`isHidden` の true 化は運営（Firebase コンソール = セキュリティルール対象外）のみが行い、クライアントからは変更不可とする（§6.2）。
- 将来 Blaze へ移行した場合は、AWS Rekognition アドオン + Webhook → Functions で isHidden を自動更新する構成に拡張できる。

```
posts/{postId}
  + isHidden: Bool   // モデレーション/運営対応で非表示。デフォルト false
```

注意点:
- 既存の posts ドキュメントには `isHidden` が存在しないため、**クエリ条件に含めると既存投稿がヒットしなくなる**。対応方針: `FirestorePost` のデコードは `isHidden` を非 Optional で持ちつつ、リリース前に既存全ドキュメントへ `isHidden: false` をバックフィルする（一括更新スクリプトまたは手動。件数は開発データのみのはずなので少ない — 要確認事項 #8）。
- 複合インデックス追加が必要: `posts` に対し `(userId, isExpired, isHidden, createdAt desc)` 相当。Firestore コンソールのエラーリンクから作成する。
- 運営（開発者）が通報対応で投稿を非表示にする手段としても `isHidden` を使う（Firebase コンソールから手動更新）。

### 2.5 24時間以内の対応フロー + 開発者通知（Blaze なし設計）

Blaze 非承認（要確認事項 #1）のため Cloud Functions は使わない。代替案を比較し、**GitHub Actions の定期実行スクリプトによるメール通知**を採用する。

#### 代替案の比較（Apple 審査基準への適合性評価）

| 案 | 内容 | Apple 審査基準（Guideline 1.2）の充足 | セキュリティ・運用 | 判定 |
|---|---|---|---|---|
| 案1: コンソール定期確認 | 開発者が Firebase コンソールの `reports` / `blocks` を毎日目視確認 | △ 通報 UI と「24時間以内に対応する」体制の宣言としては成立し得る（審査は仕組みの実在と運用の説明を見る）。ただしリジェクト文面の「開発者に通知」への直接の回答としては弱く、人的ミスで 24 時間を超過するリスクがある | 追加実装ゼロ | **予備運用として採用** |
| 案2: クライアントから直接メール送信 API（SendGrid 等）を叩く | 通報/ブロック時にアプリ自身がメール API を呼ぶ | ○ 通知は即時で要件文言は満たす | × 送信用 API キーをアプリバイナリに同梱する必要があり、抽出されるとスパム送信に悪用される。キー失効・ローテーションで通知が全停止する。通信失敗時に通知が消失する | **不採用** |
| 案3: GitHub Actions 定期実行スクリプト | 30〜60分間隔で `notified == false` の `reports` / `blocks` を Admin SDK で検出しメール送信 | ◎ 「通報・ブロックは自動的に開発者へメール通知され、24時間以内に対応する」と Review Notes に事実として記載できる。通知遅延は最大 1 時間程度で 24 時間 SLA に対して十分 | 認証情報（サービスアカウント・SMTP）は GitHub Secrets に置き、アプリに秘密を持たない。無料枠内（要確認事項 #13） | **採用** |
| （参考）Blaze + Cloud Functions | Firestore onCreate トリガーで即時メール | ◎ 最も堅牢・即時 | 従量課金（§7 で試算）。将来の移行先 | 今回は見送り |

#### 採用設計（案3 + 予備として案1）

| 成果物 | 種別 | 責務 |
|---|---|---|
| `scripts/moderation-notifier/`（Node.js） | 新規 | firebase-admin（サービスアカウント認証）で `reports` / `blocks` の `notified == false` を取得し、通知メールを **cjie46251@gmail.com** へ送信（reportId/blockId・対象ユーザー ID・理由・Firebase コンソールへの直リンクを本文に含める）。送信成功後に `notified: true` / `notifiedAt` を更新（Admin SDK はセキュリティルール対象外のため、クライアントに update を許可しなくてよい） |
| `.github/workflows/moderation-notifier.yml` | 新規 | schedule（30分間隔。Actions 枠が逼迫する場合は60分）+ workflow_dispatch（手動実行・動作確認用）。Secrets: Firebase サービスアカウント JSON / SMTP 認証情報（要確認事項 #11） |
| `docs/moderation-runbook.md` | 新規 | 運用手順書: 通知メール受信 → Firebase コンソールで対象確認 → 対応（`posts.isHidden = true` / 投稿削除 / 当該ユーザーへの措置）→ `reports.status` を "actioned" に更新、を **24時間以内** に行う手順。予備運用として 1 日 1 回のコンソール直接確認（案1）も明記 |

App Review 再提出時は Review Notes に「通報・ブロックは開発者へ自動メール通知され、24 時間以内に内容確認とコンテンツ削除・アカウント措置を行う（連絡先: cjie46251@gmail.com）」を記載する。

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
5. `blocks`: `blockerId == 自分` のものを削除。`blockedId == 自分` のものはセキュリティルール上削除できない（許可すると「ブロックされた側の自己解除」の穴になる）ため**残置**する。残置された block は相手のブロック一覧で「退会したユーザー」として表示され、解除操作は引き続き可能（T10）
6. `users/{uid}/hiddenPosts` サブコレクションを削除
7. `users/{uid}` 本体を削除
8. `reports` は**削除しない**（モデレーション記録として保持。通報者IDが消えたユーザーを指す場合があるが許容）

補足:
- **前提: users の `allow delete: if false` を「本人のみ許可」に変更する必要がある（§6.2 / T18）。T18 のルール適用前は削除フローが動作しない。** また手順 2〜3 のカウンタ減算は、修正後ルールの「カウンタのみ・±1・非負」分岐（§6.1）で許可される（1 フォロー関係につき 1 書き込みで ±1 のため）。
- Cloudinary 上の画像削除は unsigned API では不可能（Admin API は api_secret 必須でクライアントに置けない）。Blaze 非承認のため（要確認事項 #1/#6）、**画像はオーファンとして残す方針で確定**。将来必要になれば、通知スクリプトと同じ GitHub Actions 基盤（Secrets に Cloudinary api_secret を登録）で削除キューを処理できる。
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

## 6. Firestore セキュリティルール設計（要確認事項 #4 の回答と追加依頼 A/B を反映）

### 6.1 脆弱性 A の確認と修正（users の update ルール）

**指摘の確認**: その通りです。現行ルールの

```
allow update: if signedIn() && (
  request.auth.uid == userId ||
  request.resource.data.diff(resource.data).affectedKeys()
    .hasOnly(['followersCount', 'followingCount'])
);
```

は、OR の第 2 分岐が「誰が」「誰のドキュメントを」「どんな値に」更新するかを一切検証していないため、認証済みユーザーなら誰でも、**任意のユーザー**の followersCount / followingCount を**任意の値**（負数や 9,999,999 など）に書き換えられる。

**修正（採用・§6.4 のルールセットに反映済み）**: 第 2 分岐に「各カウンタの変化量が ±1 以内」「結果が非負」の制約を追加する。フォロー承認/解除・ブロック・退会処理での正当なカウンタ更新は、いずれも 1 書き込みにつき ±1 なので（§3.3 補足参照）、**既存・新規のアプリコードの変更は不要**。バッチ/トランザクション内の複数操作も 1 操作ずつルール評価されるため影響しない。

**残存リスクと将来の抜本対応（今回は見送り）**: ±1 制約後も、悪意ある認証済みユーザーが他人のカウンタを ±1 ずつ繰り返し増減させる嫌がらせは防げない。「同一トランザクションに正当な follows の作成/削除が伴うか」はドキュメント ID が不定のためルールから検証できず、ルールだけでの完全防御は不可能。抜本対応は**非正規化カウンタ（followersCount / followingCount / postsCount）を廃止し、Firestore の `count()` 集計クエリに置き換える**こと。users の update を本人のみに単純化でき、FollowService のトランザクションと退会時のカウンタ減算も不要になるが、FollowService / UserService / PostService / 各 ViewModel / FollowServiceTests に跨る中規模改修になるため今回は見送り、公開後の改善課題とする。

**その他の既知の割り切り（現行ルールのコメントで自認済みのもの）**: users の read で email が全認証ユーザーに読める点、posts の read が全認証ユーザーに開いており鍵アカ制御がクライアントのみである点は、今回のリジェクト対応の必須範囲外として現状維持とする（email はプロフィール公開部分とプライベート部分のドキュメント分離、posts はフォロー関係の `exists()` 検証が将来の改善策。T20 の複合 ID 化は posts 側の改善の前提にもなる）。

### 6.2 新規コレクションのルールとアカウント削除の有効化（追加依頼 B）

§6.4 のルールセット全文に含まれる変更点の要約:

- **users の delete**: `if false` → **本人のみ許可**。アカウント削除（T15）は「Firestore データ削除 → Auth 削除」の順で実行するため、削除時点で本人の auth は有効であり、この変更だけでクライアント側カスケード削除が成立する。
- **blocks（新規）**: 作成は blocker 本人のみ（ドキュメント ID が複合 ID `{blockerId}_{blockedId}` と一致することも強制。二重ブロックは ID 衝突で失敗）。読み取りは当事者のみ（ブロックされた側にも許可: フィード防御フィルタ `getBlockerIds` で使用する。「誰にブロックされたか」が API 上検知可能になるトレードオフは許容）。削除は blocker のみ（ブロックされた側の自己解除と、退会者による相手側ブロックの削除を防ぐ → §3.3 手順 5 の残置仕様）。更新は全面禁止（`notified` は Admin SDK のみが更新し、Admin SDK はルール対象外）。
- **reports（新規）**: 作成は reporter 本人のみ、かつ `status == "pending"` / `notified == false` の初期状態を強制。クライアントからの読み取り・更新・削除は全面禁止（運営は Firebase コンソール / Admin SDK で閲覧・更新する）。
- **users/{uid}/hiddenPosts（新規）**: 本人のみ読み取り・作成・削除可。
- **posts**: 作成時に `isHidden == false` を強制。更新時に `isHidden` の変更を禁止（運営がコンソールで true にした投稿を、投稿者が API 直叩きで自己解除するのを防ぐ）。

### 6.3 強化オプション（T20・推奨）: 複合 ID と exists() 検証

**追加で発見した問題（フィード注入）**: 現行の follows の create ルールは「`followingId == 自分`」しか検証しないため、悪意あるユーザー B が `{followerId: A, followingId: B}` のドキュメントを API 直叩きで作成でき、**A の同意なく「A が B をフォローしている」状態を作れる**。`HomeViewModel` / `WidgetDataUpdater` は follows の followerId == A から取得対象を決めるため、B は自分の投稿を A のタイムラインとウィジェットに注入できる。UGC 審査対応（不適切コンテンツの強制表示）の観点でも塞ぐことが望ましい。

**対策**: followRequests のドキュメント ID を `"{requesterId}_{targetId}"`、follows を `"{followerId}_{followingId}"` の複合 ID にし、ルールで以下を検証する:

```
// followRequests の create（強化版）
allow create: if signedIn()
  && requestId == request.resource.data.requesterId + '_' + request.resource.data.targetId
  && request.resource.data.requesterId == request.auth.uid
  && request.resource.data.targetId != request.auth.uid
  && request.resource.data.status == 'pending'
  // ブロック関係（双方向）があればサーバ側で拒否
  && !exists(/databases/$(database)/documents/blocks/$(request.auth.uid + '_' + request.resource.data.targetId))
  && !exists(/databases/$(database)/documents/blocks/$(request.resource.data.targetId + '_' + request.auth.uid));

// follows の create（強化版）
allow create: if signedIn()
  && followId == request.resource.data.followerId + '_' + request.resource.data.followingId
  && request.resource.data.followingId == request.auth.uid
  && request.resource.data.followerId != request.auth.uid
  // 対応するフォローリクエストが存在する場合のみ作成可（フィード注入の遮断）。
  // 承認トランザクション内ではリクエスト削除前の状態が参照されるため exists() は成立する
  && exists(/databases/$(database)/documents/followRequests/$(request.resource.data.followerId + '_' + request.auth.uid));
```

副次効果: followRequests / follows の重複作成も ID 衝突で防げ、`FollowService.sendFollowRequest` のブロックチェックがサーバ側でも強制される。**既存の開発データは複合 ID でないため、適用前にワイプが必要**（要確認事項 #12）。`FollowService` のドキュメント作成箇所（`document()` → `document(複合ID)`）と `FollowServiceTests` の修正を伴うため、独立タスク T20 とする。

### 6.4 ルールセット全文（T18 で `firestore.rules` としてリポジトリに追加し、コンソールへ適用）

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function signedIn() {
      return request.auth != null;
    }

    // 他人による users 更新は、フォロー承認/解除・ブロック・退会処理でのカウンタ増減のみ。
    // 1回の書き込みにつき各カウンタ ±1・結果非負に制限する（脆弱性 A の修正）
    function isValidCounterUpdate() {
      return request.resource.data.diff(resource.data).affectedKeys()
          .hasOnly(['followersCount', 'followingCount'])
        && (request.resource.data.followersCount - resource.data.followersCount) in [-1, 0, 1]
        && (request.resource.data.followingCount - resource.data.followingCount) in [-1, 0, 1]
        && request.resource.data.followersCount >= 0
        && request.resource.data.followingCount >= 0;
    }

    // ===== users =====
    match /users/{userId} {
      // 検索・プロフィール表示のため認証済みユーザーは読み取り可
      // （注意: email も読める。現状維持の割り切り。将来はドキュメント分離で改善）
      allow read: if signedIn();
      allow create: if signedIn() && request.auth.uid == userId
        && request.resource.data.followersCount == 0
        && request.resource.data.followingCount == 0
        && request.resource.data.postsCount == 0;
      allow update: if signedIn() && (
        request.auth.uid == userId ||
        isValidCounterUpdate()
      );
      // アカウント削除（T15）: 「Firestore 削除 → Auth 削除」の順のため本人 auth は有効
      allow delete: if signedIn() && request.auth.uid == userId;

      // ===== users/{userId}/hiddenPosts =====（通報者の非表示リスト）
      match /hiddenPosts/{postId} {
        allow read, create, delete: if signedIn() && request.auth.uid == userId;
        allow update: if false;
      }
    }

    // ===== posts =====
    match /posts/{postId} {
      // 開発段階: 認証済みなら読み取り可（鍵アカ制御はアプリ側ロジック。現状維持）
      allow read: if signedIn();
      allow create: if signedIn() && request.auth.uid == request.resource.data.userId
        && request.resource.data.isHidden == false;
      // isHidden は運営専用（コンソール / Admin SDK はルール対象外）。投稿者による自己解除を防ぐ
      allow update: if signedIn() && request.auth.uid == resource.data.userId
        && request.resource.data.isHidden == resource.data.isHidden;
      allow delete: if signedIn() && request.auth.uid == resource.data.userId;
    }

    // ===== followRequests =====（現行のまま。T20 採用時は §6.3 の強化版 create に差し替え）
    match /followRequests/{requestId} {
      allow read: if signedIn() && (
        resource.data.requesterId == request.auth.uid ||
        resource.data.targetId == request.auth.uid
      );
      allow create: if signedIn()
        && request.resource.data.requesterId == request.auth.uid
        && request.resource.data.targetId != request.auth.uid
        && request.resource.data.status == 'pending';
      allow update: if false;
      allow delete: if signedIn() && (
        resource.data.requesterId == request.auth.uid ||
        resource.data.targetId == request.auth.uid
      );
    }

    // ===== follows =====（現行のまま。T20 採用時は §6.3 の強化版 create に差し替え）
    match /follows/{followId} {
      allow read: if signedIn() && (
        resource.data.followerId == request.auth.uid ||
        resource.data.followingId == request.auth.uid
      );
      allow create: if signedIn()
        && request.resource.data.followingId == request.auth.uid
        && request.resource.data.followerId != request.auth.uid;
      allow update: if false;
      allow delete: if signedIn() && (
        resource.data.followerId == request.auth.uid ||
        resource.data.followingId == request.auth.uid
      );
    }

    // ===== blocks =====（新規）
    match /blocks/{blockId} {
      // 当事者のみ読み取り可（ブロックされた側の読み取りは getBlockerIds のフィード防御で使用）
      allow read: if signedIn() && (
        resource.data.blockerId == request.auth.uid ||
        resource.data.blockedId == request.auth.uid
      );
      // 作成は blocker 本人のみ。複合 ID 一致を強制（二重ブロックは ID 衝突で失敗）
      allow create: if signedIn()
        && request.resource.data.blockerId == request.auth.uid
        && request.resource.data.blockedId != request.auth.uid
        && blockId == request.resource.data.blockerId + '_' + request.resource.data.blockedId
        && request.resource.data.notified == false;
      // notified の更新は通知スクリプト（Admin SDK・ルール対象外）のみ
      allow update: if false;
      // 削除（= ブロック解除）は blocker のみ。ブロックされた側の自己解除・退会時の削除は不可
      allow delete: if signedIn() && resource.data.blockerId == request.auth.uid;
    }

    // ===== reports =====（新規）
    match /reports/{reportId} {
      // 作成は通報者本人のみ。初期状態（pending・未通知）を強制
      allow create: if signedIn()
        && request.resource.data.reporterId == request.auth.uid
        && request.resource.data.status == 'pending'
        && request.resource.data.notified == false;
      // 閲覧・対応は運営のみ（Firebase コンソール / Admin SDK はルール対象外）
      allow read, update, delete: if false;
    }
  }
}
```

---

## 7. Blaze プランの推奨判断と費用試算（追加依頼 C への回答）

### 7.1 結論

- **今回の審査再提出は「Blaze なし」で進める**（決定の通り。§2.4 / §2.5 / §3 / §6 はその前提で再設計済み）。**審査通過に Blaze は必須ではない。**
- ただし**中期的（App Store 公開後、利用が伸び始めた時点）には Blaze 承認を推奨**する。移行の目安: Firebase コンソールの使用量グラフで「1 日の読み取りが無料枠 5 万件の 50% を超えた」時点。

### 7.2 推奨理由

1. **Spark の無料枠は「課金」ではなく「停止」で効く**: Spark では読み取り 5万/日・書き込み 2万/日 の日次クォータを超えると、その日の Firestore アクセスが**エラーになりアプリ全体が動かなくなる**（タイムライン・プロフィール・ウィジェットすべて）。利用者が増えたときの最初の障害が「日中に全ユーザーでアプリが使えなくなる」という形で現れる。Blaze は同じ無料枠を含み、**超過分だけ課金される（= 止まらない）**。
2. **通知の堅牢化**: 現設計（GitHub Actions ポーリング）は 30〜60 分の遅延と GitHub への外部依存がある。Blaze なら Firestore トリガーで即時・Firebase 内で完結する。
3. **費用リスクの実体は小さい**: 下表の通り、現実的な規模では実質 ¥0〜数百円。「費用が読めない」不安には予算アラートで対処できる（§7.4）。

### 7.3 想定利用規模での月額試算

前提: DAU = MAU × 30%。1 DAU あたり読み取り 150 件/日（タイムライン 20 件 × 3 セッション + プロフィール・フォロー関係・ウィジェット更新）、書き込み 15 件/日。単価は米国マルチリージョン基準（読み取り $0.06 / 10万件、書き込み $0.18 / 10万件）。**リージョンにより単価は 2〜4 割程度上下するため、プロジェクトの Firestore ロケーションを確認して再計算すること。** $1 = ¥150 換算。

| 想定規模 | 読み取り/日 | Spark（無料）での状態 | Blaze 月額（無料枠控除後の課金額） |
|---|---|---|---|
| 100 MAU（30 DAU） | 約 4,500 | 枠内。問題なし | **¥0** |
| 1,000 MAU（300 DAU） | 約 45,000 | **無料枠 5万/日にほぼ到達。ピーク日は日中に停止するリスク** | **¥0〜約 ¥100** |
| 10,000 MAU（3,000 DAU） | 約 450,000 | **毎日クォータ超過で停止（実質運用不能）** | **約 ¥1,100〜1,500**（読み取り約 $7.2 + 書き込み約 $1.4） |

- 将来 Cloud Functions を使う場合も、通報/ブロック通知程度の呼び出し回数（多くて数百回/月）は無料枠 200 万回/月の誤差未満。付随費用（Artifact Registry 等）は月数円〜数十円。
- ストレージ: 画像は Cloudinary 側にあるため、Firestore ストレージは当面 1 GiB 無料枠内。

### 7.4 「費用が読めない」懸念への対策（Blaze 移行時）

- Cloud Billing の**予算アラート**を ¥500 / ¥1,000 / ¥3,000 の 3 段階で設定する（メール通知）。
- 注意: 予算アラートは**通知のみで自動停止はしない**（Google は旧来の支出上限機能を廃止済み）。ただし暴走課金の典型例は Cloud Functions の無限ループであり、本設計は Functions を使わないため、移行直後の課金源は Firestore 超過分のみ。単価が低く、規模に比例してしか増えないため予測可能性は高い。
- 移行時は §2.5 の通知を Functions トリガーへ差し替える（T17 の GitHub Actions は廃止してよい）。

---

## 8. 実装順序（タスクリスト）

各タスクは 1 コミット相当。**実施順は末尾の「依存関係まとめ」に従う**（タスク番号は識別子であり実施順ではない。特に T18（ルール適用）はフェーズ 4 より前に実施する）。**「完了条件」をすべて満たすこと**をコミットの条件とする。共通完了条件として全タスクで「アプリターゲットと Widget ターゲットのビルドが通ること」を含む。

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
- 内容: §2.2。`BlockService.swift` 新規（モデル・blockUser/unblockUser/getBlockedIds/getBlockerIds/isBlocked）、`FirebaseManager.blocksCollection` 追加。ドキュメント ID は複合 ID `"{blockerId}_{blockedId}"`、作成時に `notified: false` を含める。**前提: T18（blocks のルール適用。ルール未適用だとデフォルト拒否で動作しない）**。
- 完了条件:
  - `blockUser` 実行で `blocks` ドキュメントが作成され、双方向の `follows` と pending `followRequests` が削除され、関係者のフォローカウントが正しく減算される（フォロー関係がないペアでもエラーにならない）。
  - 作成された `blocks` ドキュメントの ID が `{blockerId}_{blockedId}` 形式で、`notified: false` を含む。
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
  - プロフィール取得に失敗した行（退会したユーザー等）は「退会したユーザー」と表示され、その行でもブロック解除は実行できる。
  - 0 件時は空状態表示（既存 EmptyNotificationsView と同パターン）。

### フェーズ 5: 通報（Guideline 1.2-③）

**T11. ReportService とデータ層**
- 内容: §2.3。`ReportService.swift` 新規（`FirestoreReport` / `ReportReason` / submitReport / hidePost / getHiddenPostIds）。**前提: T18（reports / hiddenPosts のルール適用）**。
- 完了条件:
  - `submitReport` で `reports` ドキュメントが §2.3 のスキーマ通り（status="pending"、notified=false）作成される。
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
- 内容: §3.2/3.3。`AuthenticationService.reauthenticate` + `.requiresRecentLogin`、`UserService.deleteUserData`、`AuthViewModel.deleteAccount(password:)` 完成、`SharedDataManager.clearWidgetData()`（logout 時にも呼ぶ）。**前提: T18（users の delete 許可を含むルール適用）**。
- 完了条件:
  - テストユーザーで `deleteAccount(password:)` 実行後、Firestore に当該ユーザーの `users` / `posts` / `follows`（双方向）/ `followRequests` / `blocks`（blockerId が自分のもの）/ `hiddenPosts` が残っていない（blockedId が自分の blocks は §3.3 手順 5 の仕様通り残る）。
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

**T17. 開発者通知（GitHub Actions 定期実行スクリプト）**
- 内容: §2.5。`scripts/moderation-notifier/` に Node.js スクリプト（firebase-admin で `reports` / `blocks` の `notified == false` を取得 → cjie46251@gmail.com へメール送信 → `notified: true` / `notifiedAt` を Admin SDK で更新）、`.github/workflows/moderation-notifier.yml`（30分間隔の schedule + workflow_dispatch）。認証情報（Firebase サービスアカウント JSON・SMTP 認証情報）は GitHub Secrets（要確認事項 #11）。`docs/moderation-runbook.md` 作成。
- 完了条件:
  - workflow_dispatch の手動実行で、未通知の通報/ブロックがメールで届き（reportId/blockId、対象ユーザーID、理由、Firebase コンソールへのリンクを含む）、該当ドキュメントの `notified` が true / `notifiedAt` が設定される。
  - 未通知ドキュメントが 0 件のときはメールが送信されない。
  - schedule 実行が有効で、間隔が 30〜60 分（Actions 無料枠は要確認事項 #13 に従う）。
  - runbook に 24 時間以内の対応手順（通知受信 → 確認 → isHidden 化/削除/アカウント措置 → reports.status を "actioned" に更新）と、予備運用（1日1回のコンソール確認）が記載されている。

**T18. Firestore セキュリティルールの更新（フェーズ 4 より前に実施）**
- 内容: §6.4 のルールセット全文を `firestore.rules` としてリポジトリに追加し、Firebase コンソールへ適用（CLI・Blaze 不要）。含まれる変更: users カウンタ更新の脆弱性 A 修正（±1・非負制約）、users の delete 許可（本人のみ）、blocks / reports / hiddenPosts のルール追加、posts の isHidden 強制（作成時 false・クライアント変更禁止）。
- 完了条件:
  - リポジトリに `firestore.rules` が存在し、内容が §6.4 と一致する。コンソールへ適用済み。
  - 他人の followersCount / followingCount を「±1 の範囲外の値」または「他フィールドと同時」に更新しようとすると拒否される（Rules Playground または Firebase Emulator で確認）。
  - 本人による users ドキュメントの削除が許可され、他人のドキュメント削除は拒否される。
  - なりすました block / report の作成（blockerId / reporterId ≠ 自分）、reports のクライアント読み取り、posts.isHidden のクライアント変更が拒否される。
  - 既存機能（フォローリクエスト送信/承認/拒否/解除、投稿作成/削除、プロフィール更新）が引き続き動作する。
  - ※ T14 実装前に適用する場合、posts の `isHidden` 条件は T14 と同時に有効化する（既存アプリコードは isHidden を書かないため、先に強制すると投稿作成が失敗する）。その場合 T18 は「isHidden 以外」を先行適用し、isHidden 条件の追加を T14 の完了条件に含める。

**T19. プレースホルダ整理（Guideline 2.1(a) スクリーンショット関連の再発防止）**
- 内容: §5。ウィジェットのモック初期化（`setupMockDataIfNeeded` / Provider のモックフォールバック）を `#if DEBUG` 限定にし、リリースビルドの空状態は `EmptyWidgetView` に委ねる。発見タブを MainTabView から削除（投稿タブの tag ハンドリングを維持）。未使用の `ContentView .swift` を削除。
- 完了条件:
  - Release 構成のビルドで、投稿ゼロのウィジェットに架空ユーザーが表示されず空状態表示になる。
  - タブが「ホーム / 投稿 / 通知 / プロフィール」の 4 つになり、投稿タブのモーダル表示が従来通り動く。
  - `ContentView .swift` 削除後もビルドが通る。
  - ※App Store Connect のスクリーンショット再撮影・差し替えはコード外の運用作業として別途実施。

**T20.（推奨・任意）follows / followRequests の複合 ID 化とルール強化**
- 内容: §6.3。`follows` のドキュメント ID を `"{followerId}_{followingId}"`、`followRequests` を `"{requesterId}_{targetId}"` の複合 ID に変更（`FollowService` の `document()` 呼び出し箇所と `FollowServiceTests` を修正）。`firestore.rules` の followRequests / follows の create を §6.3 の強化版に差し替えて再適用。既存の開発データは事前にワイプする（要確認事項 #12）。
- 完了条件:
  - フォローリクエスト送信・承認で作成されるドキュメントの ID が複合 ID 形式である。
  - followRequest が存在しない状態で follows を直接作成しようとするとルールで拒否される（Rules Playground / Emulator で確認 = フィード注入の遮断）。
  - ブロック関係があるペアの followRequest 作成がルールで拒否される。
  - フォロー送信 → 承認 → 解除 → 再フォローの一連のフローが従来通り動作し、`FollowServiceTests` がパスする。

### 依存関係まとめ

実施順はこのグラフに従う（タスク番号は識別子であり実施順ではない）:

```
T1（独立・最優先）
T2 ─┬─ T3 → T4 → T5
    ├─ T10, T16
T18（ルール適用）→ T6, T11, T15   ← blocks/reports/hiddenPosts はルールなしではデフォルト拒否
T6 → T7 → T8, T9
T6 → T10
T11 → T12（T9 のメニュー実装に依存）
T13（独立）
T14（独立。isHidden ルール強制のタイミングは T18 の注記参照）
T15 → T16
T6, T11 → T17
T18 → T20（任意・推奨。実施する場合は要確認事項 #12 の回答後）
T19（独立・提出直前で可）
```

---

## 9. 要確認事項

### 9.1 回答済み（設計へ反映済み）

1. **Firebase の料金プラン** — 回答: **Blaze は承認しない**。
   → §2.4(b) / §2.5 / §3.3 / §6 を Blaze なし前提で再設計済み。推奨判断と費用試算は §7（結論: 今回は Blaze なしで進め、公開後に読み取りが無料枠の 50% を超えた時点での移行を推奨）。
2. **開発者通知の宛先** — 回答: `cjie46251@gmail.com`。
   → §2.5 / T17 に反映。App Review の Review Notes にも記載する。
3. **規約文面の用意** — 回答: ドラフト作成はこちらで行う。EULA は Apple 標準 LAEULA を使用し、ゼロトレランス条項はアプリ内利用規約に明記。
   → §2.1 / T3 に反映済み。アプリ内静的テキストとして実装し、App Store Connect 側の EULA 設定は変更しない。
4. **Firestore セキュリティルールの現状** — 回答: 現行ルール全文を受領。
   → §6 に評価と修正設計を記載（指摘の脆弱性 A の確認と修正 §6.1、追加で発見したフィード注入問題 §6.3 を含む）。T18 で `firestore.rules` として適用。
5. **Cloudinary の画像モデレーション** — Blaze 非承認により Webhook 受け口を持てないため、**自動画像モデレーションは初回リリースでは見送りで確定**（§2.4(b)）。「NG ワード + 通報 + 24時間以内の人的対応」を審査回答の主軸にする。
6. **アカウント削除時の Cloudinary 画像** — Blaze 非承認により、**オーファンとして残置で確定**（§3.3）。将来必要になれば GitHub Actions 基盤で削除キュー処理が可能。

### 9.2 未回答（回答待ち。未回答の場合は記載のデフォルト方針で進める）

7. **プロフィール編集の範囲**: username 変更を編集対象に含めるか（投稿の非正規化フィールドとの整合処理が別途必要になる）。
   デフォルト方針: T1 では displayName / bio / プロフィール画像のみ編集可とし、username 変更は対象外。
8. **既存データのバックフィル**: 本番 Firestore の既存 `posts` に `isHidden: false` を一括付与する必要がある（T14）。現在の投稿件数の確認。
   デフォルト方針: コンソール手動対応（件数が多い場合はスクリプトを用意する）。
9. **発見タブの扱い**: 審査提出版で発見タブを非表示にするか。なお `UserProfileScreen`（他ユーザープロフィール）への導線が現状存在しないため、ブロック・通報 UI の主要導線はタイムラインカードのメニューになる。
   デフォルト方針: T19 の通り非表示にする。
10. **iPad 実機検証**: iPad Air 11-inch (M3) / iPadOS 26.x の実機またはシミュレータでの最終確認を提出前チェックリストに含める。手元の Xcode で該当 OS バージョンのシミュレータが利用可能かの確認。
11. **通知メールの送信手段（T17）**: GitHub Actions からのメール送信は Gmail の SMTP + アプリパスワード（Google アカウントの 2 段階認証が必要）を想定。cjie46251@gmail.com のアカウントでアプリパスワードを発行できるか。
    デフォルト方針: Gmail アプリパスワードを GitHub Secrets に登録して使用（不可の場合は Resend / SendGrid 等の無料枠 SMTP を利用）。
12. **開発データのワイプ（T20 の前提）**: follows / followRequests の複合 ID 化は既存ドキュメントの ID 形式と互換がないため、適用前に既存の開発用データ（follows / followRequests / blocks）を削除する必要がある。ワイプしてよいか。
    デフォルト方針: T20 を実施する場合、審査再提出前にワイプする。
13. **GitHub Actions の無料枠（T17）**: リポジトリが private の場合、Actions 無料枠は月 2,000 分。30 分間隔の通知スクリプト（約 1,440 分/月）は枠内だが、他のワークフローとの合算で超えないか確認。
    デフォルト方針: 30 分間隔で開始し、枠が逼迫したら 60 分間隔（約 720 分/月）に変更。
14. **T20（複合 ID 化とルール強化）の採否**: §6.3 のフィード注入対策。審査必須ではないが、UGC アプリのセキュリティとして実施を推奨。
    デフォルト方針: 実施する（前提: #12 のワイプ承認）。
