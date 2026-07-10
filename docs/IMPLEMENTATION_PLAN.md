# Peephole 実装プラン: ウィジェット画像表示 & ユーザー検索・フォロー機能

作成日: 2026-07-10 / 対象ブランチ: `claude/peephole-widget-search-plan-z8nhaf` から派生して作業

このドキュメントは、実装担当セッションに渡すための詳細プランです。
**コードを書き始める前に、まず「1. 現状の構造」と「5. 実装順序まとめ」を読んでください。**

- ビルド・実機/シミュレータでの動作確認は、ユーザー（開発者本人）がXcode上で行います。実装セッションはコード編集とコミットを担当します。
- 各Stepの「確認方法」は、ユーザーがXcodeで実行するためのチェックリストとして書いています。
- コメント・ログのスタイルは既存コードに合わせてください（日本語コメント、`print("✅ ...")` / `print("❌ ...")` 形式の絵文字ログ）。

---

## 1. 現状の構造（コードリーディング結果）

### 1.1 ウィジェットのデータフロー（現状）

```
[本体アプリ]
  PostCreateViewModel / HomeViewModel / RootView(起動・フォアグラウンド復帰)
        │
        ▼
  WidgetDataUpdater (Services/WidgetDataUpdater.swift, アプリ専用・Firebase依存)
        │  FollowService.getFollowingIds → PostService.getTimelinePosts(最大6件)
        │  FirestorePost.toPost() で imageURL に thumbnailURL(400px Cloudinary URL) をセット
        ▼
  SharedDataManager.saveWidgetData()  → App Group共有コンテナに widgetData.json 保存
  SharedDataManager.reloadWidget()    → WidgetCenter.shared.reloadAllTimelines()

[ウィジェット (PeepholeWidgetExtension)]
  PeepholeWidgetProvider.getTimeline()
        │  SharedDataManager.loadWidgetData() で JSON 読込
        │  48エントリ × 30分（24時間分）のタイムライン生成
        ▼
  SmallWidgetView / MediumWidgetView(PostCardView) / LargeWidgetView(CompactPostCardView)
        │
        ✗  AsyncImage(url:) でCloudinary URLを非同期ロード
           → WidgetKitのレンダリングは同期・一回きりなので永遠に .empty のまま
           → これが「灰色のプレースホルダー」の直接原因
```

- App Group ID: `group.app.takaoka.com.peephole.shared`（両ターゲットのentitlements設定済み）
- 投稿サムネイルは `CloudinaryService.generateThumbnailURL()` により既に `w_400,h_400,c_fill,q_auto,f_auto` 付きURLがFirestoreに保存されている（`FirestorePost.thumbnailURL`）。

### 1.2 主要ファイルと役割

| ファイル | ターゲット | 役割 |
|---|---|---|
| `Peephole/Models/Models.swift` | **両方** | `PeepholeUser` / `Song` / `Post` / `WidgetData`（ウィジェットと共有） |
| `Peephole/Shared/SharedDataManager.swift` | **両方** | App Group への widgetData.json 保存/読込、モックデータ生成 |
| `Peephole/Services/WidgetDataUpdater.swift` | アプリのみ | Firestoreから投稿取得→ウィジェットデータ更新（2つの入口メソッドあり） |
| `Peephole/Services/CloudinaryService.swift` | アプリのみ | 画像アップロード、変換URL生成（`generateThumbnailURL` / `generateProfileImageURL` / `String.cloudinaryURL`） |
| `Peephole/Services/PostService.swift` | アプリのみ | posts CRUD。`getTimelinePosts(userIds:limit:)` は `userId in` + `isExpired ==` + `createdAt desc` |
| `Peephole/Services/FollowService.swift` | アプリのみ | フォローリクエスト送信/承認(トランザクション)/拒否/キャンセル/解除、各種取得。**ほぼ完成済み** |
| `Peephole/Services/UserService.swift` | アプリのみ | users CRUD。`searchUsers(query:)` 前方一致検索が**実装済み** |
| `Peephole/ViewModels/HomeViewModel.swift` | アプリのみ | タイムライン。自分の投稿も含める折衷案の【TODO】コメントあり。L92/L146でウィジェット更新 |
| `Peephole/ViewModels/UserProfileViewModel.swift` | アプリのみ | フォロー状態管理。**要修正2点**（後述 S2） |
| `Peephole/ViewModels/NotificationsViewModel.swift` | アプリのみ | リクエスト一覧・承認・拒否。完成度高い |
| `Peephole/Views/Main/MainTabView.swift` | アプリのみ | 5タブ。発見タブは `DiscoverPlaceholderScreen`（プレースホルダー） |
| `Peephole/Views/Main/NotificationsScreen.swift` | アプリのみ | 承認/拒否UI実装済み。**バッジ用VMと別インスタンスになるバグあり**（後述 S5） |
| `Peephole/Views/Profile/UserProfileScreen.swift` | アプリのみ | 他ユーザープロフィール+フォローボタン実装済み |
| `PeepholeWidget/PeepholeWidget.swift` | ウィジェットのみ | Provider・エントリ・ルーティング |
| `PeepholeWidget/SmallWidgetView.swift` ほか Medium/Large | ウィジェットのみ | **AsyncImage使用（要修正）** |

### 1.3 実装済み vs 未実装の整理（課題2はかなり出来ている）

| 機能 | 状態 |
|---|---|
| `UserService.searchUsers()`（username前方一致・20件） | ✅ 実装済み |
| `FollowService` 一式（送信/承認/拒否/キャンセル/解除/状態確認） | ✅ 実装済み（承認・解除はトランザクション、カウンタ増減込み） |
| `UserProfileScreen` + フォローボタン（未フォロー/リクエスト中/フォロー中） | ✅ 実装済み（リクエスト中タップ=キャンセルだけ未配線） |
| `NotificationsScreen` 承認/拒否UI + 確認ダイアログ | ✅ 実装済み |
| **DiscoverScreen（検索UI）** | ❌ プレースホルダーのみ → **新規作成** |
| **DiscoverViewModel** | ❌ 存在しない → **新規作成** |
| 検索の大文字小文字対策（username正規化） | ❌ 未対応 → 対応必須（後述） |
| Firestore複合インデックス（followRequests用） | ❌ 未作成の可能性大 → 作成必須 |
| セキュリティルール | ❓ リポジトリ管理外（コンソール管理）→ 本プランで全文提示 |
| ウィジェット画像のローカル保存 | ❌ 未実装 → 課題1のメイン |

### 1.4 Xcodeプロジェクト構成の重要事項（新規ファイル作成時に必読）

このプロジェクトは Xcode 16 の **File System Synchronized Groups** を使っています。
`project.pbxproj` に個別ファイルの登録は無く、フォルダ単位で自動的にターゲットへ入ります。

- `Peephole/` フォルダ配下の新規ファイル → 自動的に **Peephole（本体アプリ）ターゲットのみ** に入る
- `PeepholeWidget/` フォルダ配下の新規ファイル → 自動的に **PeepholeWidgetExtension ターゲットのみ** に入る
- `Peephole/` 配下のファイルを **ウィジェットにも共有したい場合だけ**、pbxproj の例外リストへの追加が必要

現在の共有例外（`Peephole.xcodeproj/project.pbxproj` 内）:

```
778778662FFB9802003FE164 /* Exceptions for "Peephole" folder in "PeepholeWidgetExtension" target */ = {
    isa = PBXFileSystemSynchronizedBuildFileExceptionSet;
    membershipExceptions = (
        Models/Models.swift,
        Shared/SharedDataManager.swift,
    );
    target = 7787775E2FFA8639003FE164 /* PeepholeWidgetExtension */;
};
```

**新しい共有ファイル（本プランでは `Shared/WidgetImageStore.swift` の1つだけ）を追加する場合は、この `membershipExceptions` に相対パスを1行追記する**（例: `Shared/WidgetImageStore.swift,`）。
Xcode上で行う場合は「ファイル選択 → File Inspector → Target Membership → PeepholeWidgetExtension にチェック」と同じ意味。

⚠️ 逆に、Firebaseをimportするファイル（Services配下など）は**絶対にウィジェットターゲットに追加しない**こと。ウィジェットのメモリ制限（約30MB）とビルドを守るため、ウィジェット側はFirebase非依存を維持する。

---

## 2. 課題1: ウィジェットへの画像表示

### 2.1 設計方針

**原因**: WidgetKitのViewは タイムライン生成時に一度だけ同期レンダリングされ、`AsyncImage` のダウンロード完了を待たない。よってウィジェット内でのネットワーク画像表示は構造的に不可能。

**解決**: 画像のダウンロードを本体アプリ側で済ませ、App Group共有コンテナにファイルとして置き、ウィジェットは `UIImage(contentsOfFile:)` で同期読み込みする。

```
[本体アプリ側 (新規パイプライン)]
  WidgetDataUpdater
    → WidgetImagePreparer(新規): 各投稿の画像をCloudinaryから400pxでDL
    → WidgetImageStore(新規・共有): App Group内 WidgetImages/ にJPEG保存
    → Post.localImageFileName にファイル名を記録して widgetData.json 保存
    → 不要になった古い画像ファイルを削除
    → WidgetCenter reload

[ウィジェット側]
  WidgetImageStore.loadImage(fileName:) → Image(uiImage:) で同期表示
  （ファイルが無い/破損時は従来どおり灰色プレースホルダー）
```

**メモリ設計の根拠**（ウィジェット拡張の上限 ≈ 30MB）:
- 400×400 JPEGのデコード後メモリ ≈ 400×400×4byte ≈ **0.64MB**
- Largeウィジェット最大4枚 + プロフィール画像4枚(150px, 各0.09MB) ≈ **3MB弱** → 十分安全
- もしオリジナル画像(1080px以上)を読むと 1枚≈4.7MB × 4枚 ≈ 19MB で危険域。**「保存時点で400pxに落とす」ことが生命線**

**ファイル命名規則**（決定的な名前にすることでキャッシュと掃除が簡単になる）:
- 投稿画像: `post_{postId}.jpg` … 投稿は編集不可なので postId が同じなら内容も同じ → **既にファイルがあればダウンロードをスキップ**できる
- プロフィール画像: `profile_{userId}.jpg` … ユーザーが差し替える可能性があるので**毎回上書きダウンロード**（150pxで軽量なので許容）

### 2.2 Step W1: `WidgetImageStore` の新規作成（両ターゲット共有）

**新規ファイル**: `Peephole/Shared/WidgetImageStore.swift`
**ターゲット**: Peephole + PeepholeWidgetExtension（→ 1.4 の手順で pbxproj の membershipExceptions に `Shared/WidgetImageStore.swift` を追記すること！）

`SharedDataManager` と同様の static ユーティリティとして実装。**Firebaseを一切importしない**（`Foundation` + `UIKit` のみ）。

```swift
// 提供するAPI（シグネチャ案）
enum WidgetImageStore {
    // App Group内の画像ディレクトリ: {container}/WidgetImages/
    // FileManager.containerURL(forSecurityApplicationGroupIdentifier: SharedDataManager.appGroupIdentifier)
    static var imagesDirectoryURL: URL? { get }        // 無ければ createDirectory で作成
    static func fileURL(for fileName: String) -> URL?
    static func fileExists(_ fileName: String) -> Bool
    static func save(_ data: Data, fileName: String) -> Bool   // .atomic 書き込み、成否を返す
    static func loadImage(fileName: String) -> UIImage?        // UIImage(contentsOfFile:)
    static func cleanup(keeping fileNames: Set<String>)        // ディレクトリ走査し、keeping に無いファイルを削除
    static func removeAll()                                    // ログアウト時用（任意）
}
```

実装メモ:
- App Group IDは `SharedDataManager.appGroupIdentifier` を再利用（重複定義しない）
- ディレクトリ作成は `createDirectory(at:withIntermediateDirectories:true)` を保存前に毎回冪等に呼んでよい
- ログは既存スタイルで `print("✅/❌ [IMAGE] ...")`

**確認方法（ユーザー作業）**:
- この時点ではビルドが通ることのみ確認（⌘B。アプリ/ウィジェット両ターゲット）
- pbxproj編集後、Xcodeでファイルを選択し File Inspector の Target Membership に両ターゲットのチェックが付いていること

### 2.3 Step W2: `Models.swift` の `Post` にローカル画像参照を追加

**修正ファイル**: `Peephole/Models/Models.swift`

`Post` に **Optionalの** プロパティを2つ追加し、initにデフォルト値 `nil` を与える:

```swift
let localImageFileName: String?          // 投稿画像 (post_{postId}.jpg)
let localProfileImageFileName: String?   // プロフィール画像 (profile_{userId}.jpg)
```

⚠️ **必ずOptionalにする**こと。理由:
- 端末に残っている旧フォーマットの `widgetData.json`（このフィールドが無い）を新バイナリが読んでもデコードが失敗しない（`JSONDecoder` はOptionalの欠損キーをnilにする）
- 逆に旧バイナリが新JSONを読んでも未知キーは無視される
- non-Optionalにすると初回起動時に `loadWidgetData()` が失敗し、`PeepholeApp.setupMockDataIfNeeded()` がモックで上書きしてしまう事故が起きる

`FirestorePost.toPost()`（`PostService.swift`）はこの時点では変更不要（デフォルトnilが入る）。

**確認方法**: ⌘Bが両ターゲットで通ること。既存の `SharedDataManager.generateMockData()` がコンパイルエラーにならないこと（デフォルト引数で吸収される）。

### 2.4 Step W3: `CloudinaryService` にウィジェット用ダウンロードURL生成を追加

**修正ファイル**: `Peephole/Services/CloudinaryService.swift`

```swift
/// ウィジェット用画像のダウンロードURL（JPEG固定）
static func generateWidgetImageURL(from originalURL: String, size: Int = 400) -> String
// 変換: w_{size},h_{size},c_fill,q_auto,f_jpg
```

既存の `generateThumbnailURL` とほぼ同じ実装だが、**`f_auto` ではなく `f_jpg` に固定**する。

理由（落とし穴）: `f_auto` はHTTPの `Accept` ヘッダ次第で AVIF/WebP を返すことがある。`URLSession` のデフォルトAcceptで取得したデータをそのまま `.jpg` として保存すると、ウィジェット側の `UIImage(contentsOfFile:)` でのデコード互換性・サイズが読めなくなる。`f_jpg` でJPEGを保証するのが最も安全。

**重要**: ダウンロード元URLは `FirestorePost.thumbnailURL`（既に変換パラメータ入り）**ではなく**、オリジナルの `FirestorePost.imageURL` から生成すること。thumbnailURLに再度パラメータを挿入すると `.../upload/w_400,...,f_jpg/w_400,...,f_auto/...` のような多段変換URLになり挙動が読めなくなる。

プロフィール画像用は同メソッドを `size: 150` で使い回す（`userProfileImageURL` はオリジナルURLが入っている）。

**確認方法**: ユニットテスト（`PeepholeTests` に追加、Firebase不要のロジックテスト）:
- 入力 `https://res.cloudinary.com/demo/image/upload/v123/peephole/posts/abc.jpg` → `/upload/w_400,h_400,c_fill,q_auto,f_jpg/v123/...` になる
- Cloudinary以外のURL（picsum等）はそのまま返る

### 2.5 Step W4: `WidgetImagePreparer` の新規作成（本体アプリ専用）

**新規ファイル**: `Peephole/Services/WidgetImagePreparer.swift`
**ターゲット**: Peepholeのみ（pbxproj編集は不要。ウィジェットに入れないこと）

役割: `[FirestorePost]` を受け取り、画像をDL・保存した上で、ローカルファイル名入りの `[Post]` を返す。

```swift
class WidgetImagePreparer {
    static let shared = WidgetImagePreparer()

    /// 各投稿の画像を共有コンテナへ準備し、ローカル参照付きのPost配列を返す
    func preparePosts(from firestorePosts: [FirestorePost]) async -> [Post]
}
```

処理仕様:
1. 対象は先頭 **最大6件**（呼び出し元でも制限しているが二重に守る）
2. 各投稿について並行処理（`withTaskGroup`。同時実行は投稿画像+プロフィール画像で最大12リクエスト程度なので制御なしでも可。気にするなら4並列に制限):
   - **投稿画像**: fileName = `post_{postId}.jpg`
     - `WidgetImageStore.fileExists` なら**ダウンロードスキップ**（キャッシュヒット）
     - 無ければ `generateWidgetImageURL(from: post.imageURL, size: 400)` を `URLSession.shared.data(from:)` でDL（タイムアウト15秒程度の`URLRequest`推奨）
     - **保存前の防御的検証**: `UIImage(data:)` がnilでないこと。さらに `image.size` の長辺が600pxを超える or データが500KBを超える場合のみ、400pxに再リサイズ + `jpegData(compressionQuality: 0.7)` で再エンコードして保存（Cloudinaryが正しく400pxを返す限り通常は素通し保存）
   - **プロフィール画像**: `userProfileImageURL` が非nilの場合のみ。fileName = `profile_{userId}.jpg`、`size: 150`、**毎回上書き**
3. 個々の失敗は握りつぶして続行（`print("⚠️ [IMAGE] ...")`）。**失敗した場合でも、過去のファイルがディスクに残っていればそれを使う**:
   - 最終的な `localImageFileName` は「DL成否に関わらず、処理後に `fileExists` ならファイル名、無ければ nil」
   - これによりオフライン時（Firestoreはキャッシュから同じ投稿を返す）でもウィジェットの画像が消えない
4. `FirestorePost.toPost()` 相当の変換に `localImageFileName` / `localProfileImageFileName` を足した `Post` を組み立てて返す（`toPost()` にパラメータを足す形でも、Preparer内で直接 `Post(...)` を組んでもよい。**既存の `toPost()` の呼び出し箇所を壊さない**ようデフォルト引数推奨）

リサイズ処理は `CloudinaryService.resizeImage` がprivateなので、同等の小さなヘルパをPreparer内に持たせる（`UIGraphicsImageRenderer` 使用推奨）。

**確認方法**: 次のStep W5と合わせて実施（単体では呼び出し元がまだ無い）。

### 2.6 Step W5: `WidgetDataUpdater` のパイプライン統合

**修正ファイル**: `Peephole/Services/WidgetDataUpdater.swift`、`Peephole/ViewModels/HomeViewModel.swift`

現在2つある入口（`updateWidgetWithFollowingPosts` / `updateWidgetWithTimelinePosts`）の後半処理を1本の私有メソッドに統合する:

```swift
// 統合後の構造
func updateWidgetWithFollowingPosts(userId: String) async   // 既存: fetch → publish
func updateWidgetWithTimelinePosts(firestorePosts: [FirestorePost]) async  // ★asyncに変更
private func publishWidgetData(from firestorePosts: [FirestorePost]) async {
    // 1. WidgetImagePreparer.shared.preparePosts(from:) で画像準備済み [Post] を取得
    // 2. WidgetData(posts:lastUpdated:) を SharedDataManager.saveWidgetData()
    // 3. 参照中ファイル名Set（localImageFileName + localProfileImageFileName 全部）を集めて
    //    WidgetImageStore.cleanup(keeping:)
    // 4. SharedDataManager.reloadWidget()
}
```

**処理順序が重要**（落とし穴）:
- 「画像ファイル保存 → JSON保存 → 掃除 → reload」の順を厳守。JSONを先に書くと、ウィジェットがreload前に起きた場合に存在しないファイルを参照する
- cleanupはJSON保存後に行う。ウィジェットが旧JSONで描画中に旧ファイルを消す微小な競合ウィンドウがあるが、次のreloadで解消される許容範囲（気になるなら「reload後にcleanup」でも可）

`updateWidgetWithTimelinePosts` を async にしたので、呼び出し側の `HomeViewModel.swift` L92 / L146 を `await WidgetDataUpdater.shared.updateWidgetWithTimelinePosts(...)` に変更（どちらも既にasyncコンテキスト内なのでawaitを付けるだけ）。
`PostCreateViewModel` L206-209 と `PeepholeApp.RootView` は `updateWidgetWithFollowingPosts` 経由なので変更不要。

⚠️ タイムライン読み込みの体感速度を守るため、`HomeViewModel` 側では「投稿一覧を `self.posts` に反映した**後**」にウィジェット更新をawaitする現在の順序を維持する（画像DLでUI表示をブロックしない）。より丁寧にするなら `Task { await ... }` で切り離してもよい（エラーは内部でログ済み）。

**確認方法（ユーザー作業、ここが課題1の山場）**:
1. アプリを実行し、ログイン → ホーム表示。コンソールに `✅ [WIDGET] Widget updated with following posts: N posts` が出る
2. `SharedDataManager.saveWidgetData` 付近に一時的に `print(url)` を入れる（または既存ログのURLを確認）→ シミュレータの共有コンテナパスを取得
3. Macのターミナルで `ls <コンテナパス>/WidgetImages/` → `post_xxx.jpg` / `profile_xxx.jpg` が投稿数ぶん存在し、**1ファイル30〜100KB程度**であること
4. `widgetData.json` を `cat` して `localImageFileName` が入っていること

### 2.7 Step W6: ウィジェットViewの画像表示をローカル読み込みに置換

**修正ファイル**（AsyncImage使用箇所は計6つ・3ファイル）:
- `PeepholeWidget/SmallWidgetView.swift` … 背景画像 + プロフィール画像
- `PeepholeWidget/MediumWidgetView.swift`（`PostCardView`） … 同上
- `PeepholeWidget/LargeWidgetView.swift`（`CompactPostCardView`） … 同上

共通の置換パターン（背景画像の例）:

```swift
// Before: AsyncImage(url: URL(string: post.imageURL)) { phase in ... }
// After:
if let fileName = post.localImageFileName,
   let uiImage = WidgetImageStore.loadImage(fileName: fileName) {
    Image(uiImage: uiImage)
        .resizable()
        .aspectRatio(contentMode: .fill)
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
} else {
    Color.gray.opacity(0.3)
        .overlay(Image(systemName: "photo").foregroundColor(.white))
}
```

プロフィール画像も同様に `post.localProfileImageFileName` から読み、無ければ現在のプレースホルダー（白い円）を出す。

推奨: 3ファイルに同じコードを書かず、`PeepholeWidget/` 配下に小さな共通View（例 `WidgetLocalImageView.swift`、ウィジェットターゲットのみ）を1つ作って使い回す。

⚠️ 名前衝突注意: 本体アプリの `HomeScreen.swift` にも `PostCardView` が存在する（ターゲットが違うので現状は共存できている）。ウィジェット側に新規ファイルを作るとき、**本体アプリターゲットに誤って入れない**こと（synchronized groupなので `PeepholeWidget/` に置けば自動的にウィジェットのみになる）。

**確認方法（ユーザー作業）**:
1. スキームを `PeepholeWidgetExtension` に切り替えてRun（実行先ダイアログでウィジェットサイズを選択）→ ホーム画面のウィジェットに**実際の投稿写真が表示される**こと
2. Small/Medium/Largeの3サイズすべて確認（Largeは投稿が4件未満でも落ちないこと）
3. Xcodeコンソール（ウィジェットプロセス）にエラーが出ていないこと
4. 機内モードにして本体アプリを一度も開かずウィジェットを追加し直しても、保存済み画像が表示されること（オフライン耐性）

### 2.8 Step W7: モックデータとプレースホルダーの整理

**修正ファイル**: `Peephole/PeepholeApp.swift`、`Peephole/Shared/SharedDataManager.swift`、`PeepholeWidget/PeepholeWidget.swift`

- `PeepholeApp.setupMockDataIfNeeded()` を**削除**する（実データのパイプラインが完成したため。モックはリモートURLしか持たず、新方式では永遠に灰色になり紛らわしい）
- `PeepholeWidgetProvider.getTimeline()` のフォールバック `?? SharedDataManager.generateMockData()` を「空エントリ（`EmptyWidgetView` 表示、30分後に再試行）」に変更する。**未ログイン・初回起動時はモックではなく「投稿がありません」を出すのが正しい状態**
- `placeholder(in:)` と `getSnapshot(in:)` のモック利用はウィジェットギャラリーのプレビュー用として残してよい（画像は灰色になるが許容。こだわるならウィジェットのAssetsにサンプル画像を1枚入れ、モックで参照する拡張も可能だが**任意**）
- `generateMockData()` 自体はプレビュー用に残す

**確認方法**: シミュレータのアプリを削除→再インストール→ログイン前にウィジェット追加→「投稿がありません」表示。ログイン後にアプリを開いてから戻ると実データ表示。

### 2.9 課題1の通し確認チェックリスト

1. 投稿を新規作成 → 数秒後（`PostCreateViewModel` 経由の更新後）ウィジェットに新しい写真が出る
2. アプリをバックグラウンド→フォアグラウンド（`RootView` の `scenePhase` トリガ）でもウィジェット更新が走る
3. 共有コンテナの `WidgetImages/` に、widgetData.json が参照していない古いファイルが残っていない（cleanup動作）
4. 同じ投稿での再更新時、コンソールにダウンロードスキップのログ（キャッシュヒット）が出る
5. Xcode の Debug Navigator でウィジェットプロセスのメモリが数MB台であること（30MB制限に対する余裕確認）

### 2.10 課題1の落とし穴と回避策（まとめ）

| 落とし穴 | 回避策（本プランでの対応） |
|---|---|
| `AsyncImage` はWidgetKitで動かない | ローカルファイル + `Image(uiImage:)` に全面置換（W6） |
| メモリ30MB制限 | 保存時点で400px/JPEG q0.7に制限。オリジナル画像は絶対に読まない（W4/W5） |
| `f_auto` がAVIF等を返しデコード互換が崩れる | ダウンロードURLは `f_jpg` 固定（W3） |
| 旧widgetData.jsonとの互換性 | 新フィールドはOptional + デフォルトnil（W2） |
| JSONと画像ファイルの不整合（存在しないファイル参照） | 画像→JSON→cleanup→reload の順序厳守（W5） |
| プロフィール画像の差し替えが反映されない | profile_*.jpg は毎回上書きDL（W4） |
| オフライン時に画像が消える | DL失敗でもディスク上の既存ファイルを参照し続ける（W4-3） |
| 新規共有ファイルのターゲット設定漏れ → ウィジェットでコンパイルエラー | pbxprojのmembershipExceptionsに追記（1.4 / W1） |
| ウィジェットターゲットへのFirebase混入（ビルド肥大・メモリ） | 新規共有ファイルはFoundation/UIKitのみ。Preparer/Updaterはアプリ専用のまま |
| タイムラインentryへの画像データ埋め込み（アーカイブ肥大） | entryにはファイル名(String)のみ。Dataは絶対に持たせない |
| WidgetCenter.reloadのOSスロットリング | 開発中はアプリがフォアグラウンドの間のreloadは即時反映される。反映されない時はウィジェットを長押し→削除→再追加 |

---

## 3. 課題2: ユーザー検索・フォロー機能

### 3.1 設計方針

サービス層とプロフィール/通知画面は既に存在するため、**新規実装はDiscover画面まわりのみ**。ただし、セキュリティルールを正しく書くために既存コードの修正が2点必須（S2）。これを先にやらないと、ルール公開後に既存機能が権限エラーで壊れる。

データモデル（既存のまま使用）:
- `followRequests/{autoId}`: `requestId, requesterId, targetId, status("pending"), createdAt, respondedAt`
- `follows/{autoId}`: `followId, followerId, followingId, createdAt`
- `users/{uid}`: `username, displayName, email, profileImageURL, bio, isPrivate, followersCount, followingCount, postsCount, ...`

### 3.2 Step S1: usernameの正規化（小文字化）— 検索の大前提

**問題**: Firestoreの範囲クエリ（前方一致）は**大文字小文字を区別する**。現在サインアップ時に `Yuki_Tanaka` のような大文字入りusernameが登録でき、`yuki` で検索してもヒットしない。

**修正ファイル**:
1. `Peephole/Views/Auth/SignUpScreen.swift` L69-71: 入力フィルタに `.lowercased()` を追加
   （`username = newValue.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }`）
2. `Peephole/Services/UserService.swift`:
   - `createUserProfile()`: 保存直前に `username.lowercased()` を適用（防御的二重化）
   - `isValidUsername()`: 正規表現を `^[a-z0-9_]{3,}$` に変更
   - `searchUsers(query:)`: 冒頭で `query` をトリム → 先頭の `@` を除去 → `.lowercased()` してから範囲クエリに使う
   - `updateUsername()` にも同じ正規化を適用

**既存データの移行（ユーザー作業）**: Firebaseコンソール → Firestore → `users` コレクションで、既存テストユーザーの `username` に大文字が含まれていれば手で小文字に直す（テスト段階なので件数は少ないはず）。投稿に非正規化された `userName` フィールドは表示専用なので直さなくても機能は壊れない（見た目を揃えたければ同様に修正）。

**確認方法**: 新規アカウントを大文字混じりで登録 → Firestoreコンソールでusernameが小文字で保存されていること。

### 3.3 Step S2: フォロー状態チェックの修正 + リクエストキャンセルの配線（ルール互換のため必須）

**修正ファイル**: `Peephole/Services/FollowService.swift`、`Peephole/ViewModels/UserProfileViewModel.swift`

#### (a) `checkFollowStatus` のクエリを「自分基点」に変える

現在の `UserProfileViewModel.checkFollowStatus()`（L139）は
`getPendingFollowRequests(targetId: targetUserId)` で**相手宛の全リクエスト**を取得して自分が含まれるか見ている。これは:
- 他人宛のリクエスト全件を読むため、S7のセキュリティルール（「自分が当事者のリクエストのみ読める」）に**必ず違反**して permission denied になる
- 無駄な読み取りでもある

**修正**: `FollowService` のprivateメソッド `checkExistingRequest(requesterId:targetId:)` を公開メソッド化する:

```swift
/// 自分から相手への保留中リクエストが存在するか
func hasPendingRequest(from requesterId: String, to targetId: String) async throws -> Bool
```

（既存の `checkExistingRequest` をリネームして public 相当にし、`sendFollowRequest` 内の呼び出しも追随。返り値はBoolで十分）

`UserProfileViewModel.checkFollowStatus()` は `getPendingFollowRequests` の代わりにこれを使う。クエリが `requesterId == 自分` を含むため、ルール上も証明可能になる。

#### (b) 「リクエスト中」タップでキャンセル

`UserProfileViewModel.handleFollowButtonTapped()` の `case .requestPending:` が現在no-op。`FollowService.cancelFollowRequest(requesterId:targetId:)` は実装済みなので配線するだけ:
- 呼び出し成功で `followStatus = .notFollowing`
- 誤タップ防止のため、`UserProfileScreen` 側に確認ダイアログ（`confirmationDialog("リクエストを取り消しますか？")`）を追加するのが望ましい（NotificationsScreenの既存パターンを踏襲）

**確認方法**: S4完了後のE2Eシナリオ（3.9）で確認。

### 3.4 Step S3: `DiscoverViewModel` の新規作成

**新規ファイル**: `Peephole/ViewModels/DiscoverViewModel.swift`（アプリターゲットのみ・pbxproj編集不要）

既存ViewModelのスタイル（`@MainActor` / `ObservableObject` / `@Published` / エラー2点セット）に合わせる:

```swift
@MainActor
class DiscoverViewModel: ObservableObject {
    @Published var searchText: String = ""
    @Published var results: [FirestoreUser] = []
    @Published var isSearching: Bool = false
    @Published var hasSearched: Bool = false   // 「結果なし」と「未検索」の表示分岐用
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    private let userService = UserService.shared

    /// 検索実行。呼び出し側(.task(id:))でデバウンス済み
    func search(currentUserId: String) async {
        // 1. searchTextをトリム・先頭@除去・小文字化（UserService側でも正規化するが、
        //    空判定のためここでも整形する）
        // 2. 空なら results=[], hasSearched=false で終了
        // 3. isSearching=true → userService.searchUsers(query:) → 自分(currentUserId)を除外
        // 4. Task.isCancelled チェックしてから結果反映（デバウンスキャンセル対応）
        // 5. エラー時は errorMessage/showError（ただし検索は頻発するのでalertより
        //    画面内テキスト表示のほうが望ましい。実装しやすい方でよい）
    }
}
```

### 3.5 Step S4: `DiscoverScreen` の新規作成 + `MainTabView` 差し替え

**新規ファイル**: `Peephole/Views/Main/DiscoverScreen.swift`（既存のMain配下の画面と同じ場所）
**修正ファイル**: `Peephole/Views/Main/MainTabView.swift`

DiscoverScreenの構成:

```swift
struct DiscoverScreen: View {
    @StateObject private var viewModel = DiscoverViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel

    var body: some View {
        // 状態分岐:
        //  - searchText空: 案内表示（"@ユーザー名で友達を探そう" + magnifyingglassアイコン）
        //  - isSearching: ProgressView
        //  - hasSearched && results空: "「\(searchText)」に一致するユーザーが見つかりません"
        //  - results: List { UserSearchRow } .listStyle(.plain)
        List / ZStack ...
        .navigationTitle("発見")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "ユーザー名で検索")
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .task(id: viewModel.searchText) {
            // デバウンス: 0.4秒待ってから検索。searchTextが変わるとこのtaskは
            // 自動キャンセル→再起動されるので、Task.sleepがそのままデバウンスになる
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let uid = authViewModel.currentUserId else { return }
            await viewModel.search(currentUserId: uid)
        }
        .navigationDestination(for: String.self) { userId in
            UserProfileScreen(targetUserId: userId)
        }
    }
}

struct UserSearchRow: View {
    let user: FirestoreUser
    // NavigationLink(value: user.userId) {
    //   HStack: AsyncImage(プロフィール画像44px円形,
    //            URLはCloudinaryService.generateProfileImageURL(from:size:100))
    //          + VStack(displayName / @username)
    // }
    // ※本体アプリ内なのでAsyncImageでOK（ウィジェットとは事情が違う）
    // ※NotificationsScreenのFollowRequestRowのレイアウトを参考にする
}
```

実装メモ:
- 遷移は `NavigationLink(value: user.userId)`（String）+ `navigationDestination(for: String.self)`。`FirestoreUser` を直接valueにするとHashable準拠が必要になるので、userId文字列で渡すのが最小
- MainTabViewのタブ2を `DiscoverPlaceholderScreen()` → `DiscoverScreen()` に差し替え、`DiscoverPlaceholderScreen` 構造体を削除
- 検索結果行にフォローボタンは置かない（状態はUserProfileScreenが管理する。二重管理を避ける）

**確認方法（ユーザー作業）**:
1. 発見タブ → 検索フィールドに既存ユーザー名の先頭数文字を入力 → 0.4秒後に結果が出る
2. `@` 付き・大文字で入力してもヒットする（S1の正規化）
3. 自分自身が結果に出ない
4. 結果タップ → UserProfileScreenに遷移し「フォローする」ボタンが出る
5. 高速に文字を打っても検索が連発しない（コンソールのログ頻度で確認）

### 3.6 Step S5: 通知バッジのViewModel共有バグ修正

**修正ファイル**: `Peephole/Views/Main/NotificationsScreen.swift`

**問題**: `MainTabView` がバッジ表示用に `@StateObject notificationsViewModel` を持ち `.environmentObject()` で配布しているのに、`NotificationsScreen` は自前の `@StateObject private var viewModel = NotificationsViewModel()` を**別インスタンス**で作っている。このため画面内で承認/拒否してもタブのバッジ数が減らない。

**修正**: `NotificationsScreen` の宣言を `@EnvironmentObject var viewModel: NotificationsViewModel` に変更（`@StateObject` の行を削除）。`#Preview` には `.environmentObject(NotificationsViewModel())` を追加。

**確認方法**: E2Eシナリオ（3.9）で、リクエスト承認後にタブバッジが即座に減ることを確認。

### 3.7 Step S6: Firestore複合インデックスの作成（ユーザー作業）

コードに先立ち・遅くとも**E2Eテスト前**にFirebaseコンソールで作成する。インデックス構築には数分かかる。

| # | コレクション | フィールド | 用途 | 状態 |
|---|---|---|---|---|
| 1 | `posts` | `userId` ASC, `isExpired` ASC, `createdAt` DESC | `getTimelinePosts`（in+等価+順序） / `getUserPosts` | タイムラインが既に動作しているなら**作成済みのはず。要確認** |
| 2 | `followRequests` | `targetId` ASC, `status` ASC, `createdAt` DESC | `getPendingFollowRequests`（通知画面） | **未作成の可能性大。必須** |

- それ以外のクエリ（`follows` の等価条件のみ、`followRequests` の等価条件のみ、`users` の単一フィールド範囲検索）は自動単一フィールドインデックスで動くため**複合インデックス不要**
- 作成方法A（推奨・確実）: 該当クエリを一度実行し、Xcodeコンソールに出る `FAILED_PRECONDITION ... https://console.firebase.google.com/...` の**URLをクリックして自動作成**（フィールド構成を間違えない最速の方法）
- 作成方法B: コンソール → Firestore → インデックス → 複合 → 上表のとおり手動作成
- 注意: インデックスが「有効」になるまで該当クエリは失敗する。通知画面が「読み込みに失敗しました」を出す場合はまずインデックス構築中でないか確認

### 3.8 Step S7: セキュリティルールの公開（ユーザー作業 + 検証）

**前提**: S2(a)の修正が終わっていること（終わっていないとプロフィール画面のフォロー状態チェックが permission denied になる）。

現在のルールはリポジトリ管理外（おそらくテストモード）。以下をFirebaseコンソール → Firestore → ルール に貼り付けて公開する。
**このルールセットは、本プラン適用後のアプリが発行する全クエリが通ることを机上検証済み**（各クエリとルールの対応は表の後に記載）。

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {

    function signedIn() {
      return request.auth != null;
    }

    // ===== users =====
    match /users/{userId} {
      // 検索・プロフィール表示のため認証済みユーザーは読み取り可
      // （注意: emailも読めてしまう。開発段階の割り切り。将来の改善は §6 参照）
      allow read: if signedIn();
      allow create: if signedIn() && request.auth.uid == userId;
      allow update: if signedIn() && (
        // 本人は全フィールド更新可
        request.auth.uid == userId ||
        // 他人はフォロー承認/解除トランザクションでのカウンタ増減のみ可
        request.resource.data.diff(resource.data).affectedKeys()
          .hasOnly(['followersCount', 'followingCount'])
      );
      allow delete: if false;
    }

    // ===== posts =====
    match /posts/{postId} {
      // 開発段階: 認証済みなら読み取り可（鍵アカ制御はアプリ側ロジック。将来強化は §6）
      allow read: if signedIn();
      allow create: if signedIn() && request.auth.uid == request.resource.data.userId;
      allow update: if signedIn() && request.auth.uid == resource.data.userId;
      allow delete: if signedIn() && request.auth.uid == resource.data.userId;
    }

    // ===== followRequests =====
    match /followRequests/{requestId} {
      // 当事者（送信者 or 受信者）のみ読み取り可
      allow read: if signedIn() && (
        resource.data.requesterId == request.auth.uid ||
        resource.data.targetId == request.auth.uid
      );
      // 作成は送信者本人・自分宛以外・pendingのみ
      allow create: if signedIn()
        && request.resource.data.requesterId == request.auth.uid
        && request.resource.data.targetId != request.auth.uid
        && request.resource.data.status == 'pending';
      // 承認は「リクエスト削除+follows作成」で完結するため update は不要
      allow update: if false;
      // 削除 = キャンセル（送信者）or 承認/拒否時の後始末（受信者）
      allow delete: if signedIn() && (
        resource.data.requesterId == request.auth.uid ||
        resource.data.targetId == request.auth.uid
      );
    }

    // ===== follows =====
    match /follows/{followId} {
      // 当事者のみ読み取り可
      allow read: if signedIn() && (
        resource.data.followerId == request.auth.uid ||
        resource.data.followingId == request.auth.uid
      );
      // 作成できるのは承認操作を行う「フォローされる側」のみ
      allow create: if signedIn()
        && request.resource.data.followingId == request.auth.uid
        && request.resource.data.followerId != request.auth.uid;
      allow update: if false;
      // 削除 = フォロー解除（follower）／将来のフォロワー削除（following）
      allow delete: if signedIn() && (
        resource.data.followerId == request.auth.uid ||
        resource.data.followingId == request.auth.uid
      );
    }
  }
}
```

**机上検証（アプリの全クエリ vs ルール）**:

| アプリの操作 | クエリ/書き込み | 通る理由 |
|---|---|---|
| 検索 | `users` range query | read: signedIn |
| タイムライン/ウィジェット | `posts` where userId in [...] | read: signedIn |
| リクエスト送信 | `followRequests` create (requesterId=自分) | create条件どおり |
| リクエスト送信前チェック | `followRequests` where requesterId==自分 (S2で修正済み) | 読み取りルールの第1項がクエリから証明可能 |
| 通知一覧 | `followRequests` where targetId==自分+status+order | 読み取りルールの第2項が証明可能（要インデックス#2） |
| 承認トランザクション | request読取(targetId=自分)/follows作成(followingId=自分)/自分のfollowersCount+1/**相手の**followingCount+1(カウンタのみ)/request削除(targetId=自分) | 全操作が上記ルールに適合 |
| 拒否/キャンセル | followRequests delete | 当事者削除OK |
| フォロー解除トランザクション | follows検索(followerId==自分)→delete/自分のfollowingCount-1/**相手の**followersCount-1 | 同上 |
| フォロー状態確認 | `follows` where followerId==自分 | 読み取り第1項が証明可能 |

**重要な落とし穴（このルール設計の背景）**:
1. **カウンタ問題**: 承認/解除トランザクションは「他人のusersドキュメント」のカウンタを増減する。素朴に「本人のみupdate可」と書くとフォロー承認が必ず失敗する。`diff().affectedKeys().hasOnly([...])` で「カウンタ2フィールドだけなら他人でも可」としている（改ざん耐性は低いが開発段階の割り切り。厳密化はCloud Functions行き→§6）
2. **listクエリの証明可能性**: Firestoreはlist時にルールを「クエリ条件から全結果がルールを満たすと証明できるか」で評価する。だからこそS2(a)の修正（相手宛リクエスト全件取得をやめる）が**ルール公開前に必須**
3. **単体テストへの影響**: `PeepholeTests/FollowServiceTests.swift` は無認証で本番Firestoreに直接書き込むため、**このルール公開後は失敗するようになる**。当面は実行対象から外すか、テスト冒頭でテストユーザーにサインインする改修が必要（→§6。プラン本体のスコープ外とする）

**確認方法**: ルール公開後、E2Eシナリオ（3.9）を通しで実施。どこかで「permission denied」系エラーが出たらXcodeコンソールのエラー内容とルールを突き合わせる。Firebaseコンソールの「ルールプレイグラウンド」でも代表ケース（他人のuser docのdisplayName更新→拒否、カウンタのみ更新→許可）を検証できる。

### 3.9 課題2の通し確認: 2アカウントE2Eシナリオ（ユーザー作業）

**準備**:
- インデックス2件が「有効」（S6）、ルール公開済み（S7）
- シミュレータ2台（例: iPhone 16 と iPhone 16 Pro）にそれぞれアカウントA/Bでログイン。1台でログイン/ログアウト切り替えでも可だがバッジ確認がしやすいのは2台
- App Checkをenforcement有効にしている場合、各シミュレータのデバッグトークン（起動ログに出る）をコンソールに登録しておくこと（DEBUGビルドは `AppCheckDebugProviderFactory` 使用）

| # | 操作 | 期待結果 / Firestoreコンソールでの確認 |
|---|---|---|
| 1 | A: サインアップ（例 `usera`）、写真付きで1件投稿 | `users/{A}` 作成、`posts` に1件 |
| 2 | B: サインアップ（例 `userb`） | `users/{B}` 作成 |
| 3 | B: 発見タブで `use` と入力 | A・Bのうち**Aのみ**表示（自分は除外） |
| 4 | B: Aをタップ → プロフィール | 「フォローする」（青）。投稿グリッドは「フォローすると表示されます」 |
| 5 | B: フォローする | ボタンが「リクエスト中」（灰）に。`followRequests` に pending 1件 |
| 6 | B: もう一度タップ → 取り消し確認 → 取り消す | 「フォローする」に戻る。`followRequests` 空。**再度リクエスト送信して次へ** |
| 7 | A: 通知タブ | バッジ「1」、`@userb` の行に承認/拒否ボタン |
| 8 | A: 拒否 | 行が消える・バッジ0。`followRequests` 空。**B側から再度リクエスト** |
| 9 | A: 承認 | 行が消える・**バッジが即0になる（S5の修正確認）**。`follows` に1件、`users/{A}.followersCount=1`、`users/{B}.followingCount=1`、リクエスト消滅 |
| 10 | B: ホームをPull-to-Refresh | Aの投稿がタイムラインに出る（+現仕様では自分の投稿も） |
| 11 | B: アプリをバックグラウンド→再フォアグラウンド → ホーム画面のウィジェット | **Aの投稿が写真付きで表示される（課題1×課題2の統合確認）** |
| 12 | B: Aのプロフィール → 「フォロー中」→タップでフォロー解除 | カウンタが両者とも0に戻り、投稿グリッド非表示。リフレッシュ後タイムラインからAの投稿が消える |

### 3.10 課題2の落とし穴と回避策（まとめ）

| 落とし穴 | 回避策 |
|---|---|
| 前方一致検索の大文字小文字不一致 | username全面小文字化（S1）+ 既存データ手動修正 |
| 部分一致検索はFirestoreでは不可能 | 前方一致のみと割り切る（既存実装踏襲）。全文検索は将来Algolia等 |
| `in` クエリ最大10件制限 | 既存の `prefix(10)` を維持（フォロー11人以上で欠落する既知の制限→§6） |
| 相手宛リクエスト全件読み取りがルール違反になる | S2(a)を**ルール公開より先に**実施 |
| カウンタ更新が他人ドキュメントへの書き込みになる | ルールで `affectedKeys().hasOnly` 許可（S7） |
| インデックス未作成で通知画面がエラー | S6を先に。エラーメッセージ内URLから作成が確実 |
| バッジが減らない | NotificationsScreenを共有VM化（S5） |
| App Check有効時に2台目シミュレータが弾かれる | 各端末のデバッグトークンをコンソール登録（3.9準備） |
| ルール公開でFollowServiceTestsが落ちる | 既知として許容 or テスト側でサインイン（§6） |
| `.task(id:)` デバウンス中の結果競合 | `Task.isCancelled` チェック後に結果反映（S3） |

---

## 4. 仕上げ（E2E成功後に実施）: F1 — ウィジェットを「友達の投稿のみ」に戻す

設計方針どおり「ホーム=自分+友達 / ウィジェット=友達のみ」に分離する。**E2Eで相互フォローが確認できるまでは着手しない**（それまで自分の投稿がウィジェット確認の唯一の手段のため）。

**修正ファイル**: `Peephole/Services/WidgetDataUpdater.swift`、`Peephole/ViewModels/HomeViewModel.swift`

1. `updateWidgetWithFollowingPosts()` 内の「【動作確認用】自分自身のIDも追加」ブロック（L32-36）を削除。フォロー0人なら空の `WidgetData` を保存する（`targetUserIds.isEmpty` で return している現在の挙動を「空データを保存してreload」に変える。returnのままだと古い自分の投稿が残り続ける）
2. `publishWidgetData` / `updateWidgetWithTimelinePosts` に `excludingUserId: String` パラメータを追加し、`firestorePosts.filter { $0.userId != excludingUserId }` してから先頭6件を使う。`HomeViewModel` は自分のuserIdを渡す
3. `HomeViewModel` の3箇所の【TODO】コメント（自分をタイムラインに含める折衷案）は**ホーム画面仕様として正式採用**なのでTODO文言を「仕様: 自分の投稿もホームに表示する」に書き換える（ウィジェットにだけ流れないことを明記）

**確認方法**: フォロー0の新規アカウントでウィジェットが「投稿がありません」になること。相互フォロー後は友達の投稿のみが出て、自分の投稿が出ないこと。

---

## 5. 実装順序まとめ（この順で実施・コミット）

課題1が先。理由: (1) 現仕様では自分の投稿がウィジェットに出るため、フォロー機能なしで今すぐ検証できる、(2) 技術リスク（WidgetKit/App Groups）が高い方を先に潰す、(3) 課題2のE2E最終確認（手順11）で課題1の成果をそのまま使える。

| 順 | Step | 内容 | 主なファイル | 区分 |
|---|---|---|---|---|
| 1 | W1 | WidgetImageStore新規（共有）+ pbxproj例外追記 | Shared/WidgetImageStore.swift, project.pbxproj | コード |
| 2 | W2 | PostにlocalImageFileName等追加（Optional） | Models/Models.swift | コード |
| 3 | W3 | ウィジェット用URL生成（f_jpg）+ ロジックテスト | Services/CloudinaryService.swift | コード |
| 4 | W4 | WidgetImagePreparer新規（アプリ専用） | Services/WidgetImagePreparer.swift | コード |
| 5 | W5 | WidgetDataUpdater統合・async化 | Services/WidgetDataUpdater.swift, ViewModels/HomeViewModel.swift | コード |
| 6 | W6 | ウィジェット3View置換（+共通View） | PeepholeWidget/*.swift | コード |
| 7 | W7 | モック整理（seed削除・fallback変更） | PeepholeApp.swift, SharedDataManager.swift, PeepholeWidget.swift | コード |
| 8 | — | **課題1通し確認（2.9）** → コミット「ウィジェットに投稿画像を表示（App Group経由のローカル画像方式）」 | | 確認 |
| 9 | S1 | username小文字化 + 既存データ修正 | SignUpScreen.swift, UserService.swift + コンソール | コード+運用 |
| 10 | S2 | hasPendingRequest公開 / checkFollowStatus修正 / キャンセル配線 | FollowService.swift, UserProfileViewModel.swift, UserProfileScreen.swift | コード |
| 11 | S3 | DiscoverViewModel新規 | ViewModels/DiscoverViewModel.swift | コード |
| 12 | S4 | DiscoverScreen新規 + タブ差し替え | Views/Main/DiscoverScreen.swift, MainTabView.swift | コード |
| 13 | S5 | 通知バッジVM共有化 | NotificationsScreen.swift | コード |
| 14 | S6 | 複合インデックス2件作成 | Firebaseコンソール | 運用 |
| 15 | S7 | セキュリティルール公開 | Firebaseコンソール | 運用 |
| 16 | — | **E2Eシナリオ（3.9）** → コミット「ユーザー検索・フォローリクエストフロー完成」 | | 確認 |
| 17 | F1 | ウィジェットを友達のみに | WidgetDataUpdater.swift, HomeViewModel.swift | コード |
| 18 | — | 最終確認 → コミット「ウィジェットをフォロー中ユーザーの投稿のみに変更」 | | 確認 |

コミットは上表の3つに加え、W5終了時点など動く区切りで細かく切ってよい（メッセージは既存履歴に合わせ日本語1行）。

---

## 6. スコープ外・将来課題（今回は実装しない）

- **postsの読み取り制御の厳密化**: 現ルールは認証済み全員がpostsを読める。鍵アカを厳密にするには `follows` のドキュメントIDを `{followerId}_{followingId}` の決定的IDに変えてルールから `exists()` 参照する設計変更が本命（unfollow/checkIfFollowingのクエリも単純化される）。ただしlistクエリの証明可能性の問題が残るため、フィード用データの非正規化かCloud Functionsとセットで検討
- **カウンタ整合性の厳密化**: Cloud Functions（onDocumentCreated/Deleted）でサーバ側更新に移行し、usersのupdateルールを本人のみに絞る
- **`users` の `email` フィールド露出**: user docからemailを外す（Authにあるので不要）か、privateサブコレクションへ分離
- **フォロー11人以上**: `in` 10件制限により、タイムライン/ウィジェットの対象ユーザーを10人で切っている。クエリ分割（chunk毎に発行してマージ）で対応可能
- **FollowServiceTestsのルール対応**: Firestoreエミュレータ導入 or テスト用アカウントでのサインイン
- **ページネーションの正式実装**: `startAfter(DocumentSnapshot)` 方式へ（現在は取り直しての差分追加）
- **ウィジェットのディープリンク処理**: `peephole://post/{id}` を `onOpenURL` で受けて投稿詳細へ遷移（投稿詳細画面自体が未実装）
- **通知のリアルタイム化**: followRequestsのsnapshotリスナー化 + プッシュ通知（FCM）
- **ウィジェットギャラリー用サンプル画像**: Assetsにバンドルしてplaceholderを綺麗にする
