# Firestore Rules Playground テストケース一覧

対象: `firestore.rules`（T18。`docs/review-fix-design.md` §6.4 準拠、posts.isHidden 条件は T14 まで無効化）

Firebase コンソール → Firestore Database → ルール → 「Rules Playground」で、各ケースの
「認証」「操作」「場所」「入力データ」を設定して実行し、期待結果と一致するか確認してください。

前提条件（Playground の「シミュレーションを認証済みにする」欄）:
- `signedIn()` を満たすケースでは Auth UID を入力する（例 `userA`）。
- 未認証ケースでは「認証済みにする」のチェックを外す。

既存ドキュメント（`resource.data` として参照されるもの）は Playground の
「ドキュメントの内容（既存）」欄に事前投入するデータとして入力してください。
（コンソールの Rules Playground は「更新前のドキュメント」を別途指定できます）

---

## 1. users / followersCount・followingCount のカウンタ更新（脆弱性A修正の検証）

### 1-1. 他人の followersCount を +1 で書き換え → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `update`
- パス: `/users/userA`
- 既存ドキュメント: `{ followersCount: 5, followingCount: 3, ... }`（他フィールドは任意の既存値）
- 送信データ（更新後の全フィールド）: `{ followersCount: 6, followingCount: 3, ... }`（followersCount のみ +1、他は既存値のまま）
- 期待結果: **拒否**
- 検証内容: `isValidCounterUpdate()` は「本人 (`request.auth.uid == userId`) でない限り」カウンタ更新を許可しない設計ではなく、**他人でも ±1・非負なら許可**する仕様（フォロー承認/解除用）。よって本来この操作単体は「許可」されうる点に注意。**このケースは仕様通り許可されるはずなので、意図的に「許可」を期待値として確認するテストとして使う**（下記1-2・1-3との対比用）。

> 補足: 「他人の followersCount を ±1」自体はフォロー機能の正当な操作として設計上許可されます（§6.1「1回の書き込みにつき各カウンタ±1」）。悪意ある不正操作として拒否させたい場合は、後述 1-2（±1 の範囲外）または 1-4（他フィールドとの同時変更）で検証してください。

### 1-2. 他人の followersCount を +100 で書き換え → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `update`
- パス: `/users/userA`
- 既存ドキュメント: `{ followersCount: 5, followingCount: 3, ... }`
- 送信データ: `{ followersCount: 105, followingCount: 3, ... }`
- 期待結果: **拒否**
- 検証内容: `isValidCounterUpdate()` の `(followersCount 変化量) in [-1, 0, 1]` 制約により、±1 を超える変化は拒否されることを確認する（脆弱性A: 任意の値への書き換えができないこと）。

### 1-3. 他人の followersCount を負の値にする書き換え → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `update`
- パス: `/users/userA`
- 既存ドキュメント: `{ followersCount: 0, followingCount: 3, ... }`
- 送信データ: `{ followersCount: -1, followingCount: 3, ... }`
- 期待結果: **拒否**
- 検証内容: `request.resource.data.followersCount >= 0` 制約により、非負制約が効いていることを確認する。

### 1-4. 他人のカウンタ更新と同時に displayName も書き換え → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `update`
- パス: `/users/userA`
- 既存ドキュメント: `{ followersCount: 5, followingCount: 3, displayName: "元の名前", ... }`
- 送信データ: `{ followersCount: 6, followingCount: 3, displayName: "書き換えられた名前", ... }`
- 期待結果: **拒否**
- 検証内容: `isValidCounterUpdate()` の `affectedKeys().hasOnly(['followersCount', 'followingCount'])` により、カウンタ以外のフィールドを他人が同時変更できないことを確認する（脆弱性A: 「誰でもカウンタ更新に便乗して他フィールドを書き換えられる」穴が塞がれていること）。

### 1-5. 本人による followersCount 以外のフィールド更新 → 許可されるか

- 認証 UID: `userA`
- 操作種別: `update`
- パス: `/users/userA`
- 既存ドキュメント: `{ followersCount: 5, displayName: "元の名前", ... }`
- 送信データ: `{ followersCount: 5, displayName: "新しい表示名", ... }`
- 期待結果: **許可**
- 検証内容: `request.auth.uid == userId` の分岐により、本人であれば任意のフィールド更新が引き続き可能であることを確認する（EditProfileScreen 等の既存機能が壊れていないこと）。

### 1-6. 正当なフォロー承認によるカウンタ+1（本人以外・単一カウンタのみ・±1） → 許可されるか

- 認証 UID: `userB`
- 操作種別: `update`
- パス: `/users/userA`
- 既存ドキュメント: `{ followersCount: 5, followingCount: 3, ... }`
- 送信データ: `{ followersCount: 6, followingCount: 3, ... }`
- 期待結果: **許可**
- 検証内容: フォロー承認・解除・ブロック・退会時のカウンタ調整（他人による正当な ±1 更新）が引き続き動作することを確認する。1-1 と同一の入力だが、ここでは「許可されること」自体を確認目的とする。

---

## 2. follows の直接作成（フィード注入の可否）

### 2-1. follows を直接作成して他人のフィードに注入 → 拒否されるか

- 認証 UID: `userB`（悪意あるユーザー）
- 操作種別: `create`
- パス: `/follows/{任意のドキュメントID、例 "abc123"}`
- 送信データ: `{ followId: "abc123", followerId: "userA", followingId: "userB", createdAt: (timestamp) }`
- 期待結果: **拒否**
- 検証内容: follows の create ルール `request.resource.data.followingId == request.auth.uid` により、`followingId` が自分（`userB`）以外のドキュメントは作成できないことを確認する。これにより「B が A の同意なく `{followerId: A, followingId: B}` を偽装して A のタイムラインに自分の投稿を注入する」攻撃が阻止されることを検証する。

> 注記: T18 時点の follows ルールは `followingId == 自分` の検証のみを行い、「対応する followRequest が存在するか」までは検証しません（この強化は複合ID化とあわせて T20 で対応）。そのため、下記 2-2 のように `followingId` を自分自身にした偽装 follows は T18 のルールでは **許可されてしまいます**（既知の残存リスクとして §6.3 に記載済み）。

### 2-2.（参考・既知の残存リスク）自分を followingId にした無承認 follows の直接作成 → T18時点では許可されてしまう

- 認証 UID: `userB`
- 操作種別: `create`
- パス: `/follows/{任意のドキュメントID}`
- 送信データ: `{ followId: "xyz789", followerId: "userA", followingId: "userB", createdAt: (timestamp) }`
- 期待結果: **許可されてしまう（T18時点の既知の限界。T20で対策予定）**
- 検証内容: `followingId == request.auth.uid` は満たすため、対応する `followRequests` が存在しなくても follows が作成できてしまうことを確認する。T20 で `exists(/followRequests/...)` 検証が入るまでの残存リスクとして記録する目的のテスト。

---

## 3. users の削除

### 3-1. 本人による users 削除 → 許可されるか

- 認証 UID: `userA`
- 操作種別: `delete`
- パス: `/users/userA`
- 期待結果: **許可**
- 検証内容: アカウント削除機能（T15）の前提となる「本人は自身の users ドキュメントを削除できる」ことを確認する。

### 3-2. 他人による users 削除 → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `delete`
- パス: `/users/userA`
- 期待結果: **拒否**
- 検証内容: `request.auth.uid == userId` の制約により、他人のアカウントを削除できないことを確認する。

### 3-3. 未認証での users 削除 → 拒否されるか

- 認証: なし（未認証）
- 操作種別: `delete`
- パス: `/users/userA`
- 期待結果: **拒否**
- 検証内容: `signedIn()` チェックにより未認証リクエストが弾かれることを確認する。

---

## 4. blocks（なりすまし作成の防止）

### 4-1. 本人（blocker）による blocks 作成 → 許可されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/blocks/userA_userB`
- 送信データ: `{ blockId: "userA_userB", blockerId: "userA", blockedId: "userB", createdAt: (timestamp), notified: false }`
- 期待結果: **許可**
- 検証内容: ドキュメントID（複合ID）と blockerId が一致し、`notified: false` を含む正当な作成が許可されることを確認する。

### 4-2. なりすました blocks 作成（blockerId ≠ 自分） → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `create`
- パス: `/blocks/userA_userC`
- 送信データ: `{ blockId: "userA_userC", blockerId: "userA", blockedId: "userC", createdAt: (timestamp), notified: false }`
- 期待結果: **拒否**
- 検証内容: `request.resource.data.blockerId == request.auth.uid` により、他人になりすまして blocks を作成できないことを確認する。

### 4-3. ドキュメントIDと blockerId/blockedId の不一致 → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/blocks/wrongDocId`
- 送信データ: `{ blockId: "wrongDocId", blockerId: "userA", blockedId: "userB", createdAt: (timestamp), notified: false }`
- 期待結果: **拒否**
- 検証内容: `blockId == blockerId + '_' + blockedId` の一致検証により、ドキュメントIDの偽装（複合IDと異なるID）が拒否されることを確認する。

### 4-4. notified: true での blocks 新規作成 → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/blocks/userA_userB`
- 送信データ: `{ blockId: "userA_userB", blockerId: "userA", blockedId: "userB", createdAt: (timestamp), notified: true }`
- 期待結果: **拒否**
- 検証内容: `request.resource.data.notified == false` により、クライアントが最初から通知済み状態を偽装できないことを確認する。

### 4-5. blockedId 本人による blocks 削除（自己解除） → 拒否されるか

- 認証 UID: `userB`（ブロックされた側）
- 操作種別: `delete`
- パス: `/blocks/userA_userB`
- 既存ドキュメント: `{ blockerId: "userA", blockedId: "userB", ... }`
- 期待結果: **拒否**
- 検証内容: `resource.data.blockerId == request.auth.uid` により、ブロックされた側は自分自身の意思でブロックを解除できないことを確認する（§3.3 の退会時残置仕様の前提）。

### 4-6. blocker 本人による blocks 削除（ブロック解除） → 許可されるか

- 認証 UID: `userA`（ブロックした側）
- 操作種別: `delete`
- パス: `/blocks/userA_userB`
- 既存ドキュメント: `{ blockerId: "userA", blockedId: "userB", ... }`
- 期待結果: **許可**
- 検証内容: blocker 本人によるブロック解除が引き続き可能であることを確認する。

### 4-7. blocks の notified フィールドをクライアントから更新 → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `update`
- パス: `/blocks/userA_userB`
- 既存ドキュメント: `{ blockerId: "userA", blockedId: "userB", notified: false }`
- 送信データ: `{ blockerId: "userA", blockedId: "userB", notified: true }`
- 期待結果: **拒否**
- 検証内容: `allow update: if false` により、blocks の更新（notified の自己更新を含む）がクライアントから一切できず、通知スクリプト（Admin SDK）専用であることを確認する。

### 4-8. 存在しない blocks ドキュメントへの get（存在チェック） → 拒否される（権限エラー1の原因）

- 認証 UID: `userA`
- 操作種別: `get`（読み取り）
- パス: `/blocks/userA_userB`
- 既存ドキュメント: **なし（空欄のまま。ドキュメント非存在をシミュレートする）**
- 期待結果: **拒否**
- 検証内容: read ルール `resource.data.blockerId == ... || resource.data.blockedId == ...` は、ドキュメントが存在しない場合 `resource` が `null` になり `resource.data` 参照が評価エラー → 拒否になる。BlockService が初回ブロック時にこの point get で二重ブロックの事前チェックをしていたため、ブロック（および `isBlocked` を呼ぶフォローリクエスト送信）が毎回この段階で失敗していた。**修正はクライアント側で行い、存在判定を単一フィールドの list クエリ（`getBlockedIds` / `getBlockerIds`）に置き換える。`firestore.rules` は変更しない。** 4-1〜4-7 が単一ドキュメントの create/delete/update（＝既存 `resource` を前提）しか検証しておらず、「非存在ドキュメントへの get」を1件も持っていなかったため、このケースがすり抜けた。

---

## 5. reports（なりすまし作成・クライアント読み取りの防止）

### 5-1. 本人（reporter）による reports 作成 → 許可されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/reports/{任意のドキュメントID}`
- 送信データ: `{ reportId: "r1", reporterId: "userA", targetType: "post", targetPostId: "p1", targetUserId: "userB", reason: "spam", detail: null, status: "pending", notified: false, createdAt: (timestamp) }`
- 期待結果: **許可**
- 検証内容: reporter 本人による、初期状態（pending・未通知）を満たす通報作成が許可されることを確認する。

### 5-2. なりすました reports 作成（reporterId ≠ 自分） → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `create`
- パス: `/reports/{任意のドキュメントID}`
- 送信データ: `{ reportId: "r2", reporterId: "userA", targetType: "post", targetPostId: "p1", targetUserId: "userC", reason: "spam", status: "pending", notified: false, createdAt: (timestamp) }`
- 期待結果: **拒否**
- 検証内容: `request.resource.data.reporterId == request.auth.uid` により、他人になりすまして通報を作成できないことを確認する。

### 5-3. status を "actioned" にした reports 作成 → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/reports/{任意のドキュメントID}`
- 送信データ: `{ reportId: "r3", reporterId: "userA", ..., status: "actioned", notified: false, createdAt: (timestamp) }`
- 期待結果: **拒否**
- 検証内容: `request.resource.data.status == 'pending'` により、初期状態を偽装した作成ができないことを確認する。

### 5-4. reports のクライアント読み取り → 拒否されるか

- 認証 UID: `userA`（自分が作成した通報であっても）
- 操作種別: `get`（読み取り）
- パス: `/reports/r1`
- 期待結果: **拒否**
- 検証内容: `allow read: if false` により、通報者本人であっても reports をクライアントから直接読み取れず、運営（コンソール / Admin SDK）専用であることを確認する。

---

## 6. posts（isHidden 条件・T14 で有効化）

**前提**: 以下のケースは、既存 posts 全ドキュメントへの `isHidden: false` バックフィルが
コンソールで完了していることを前提とする。バックフィル未実施の状態で 6-5 以降の
update 系ケースを実行すると、既存ドキュメントに `isHidden` フィールドが無いために
意図せず拒否される（フィールド未定義参照によるエラー）。

### 6-1. isHidden: false を明示した投稿作成 → 許可されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/posts/{任意のドキュメントID}`
- 送信データ: `{ postId: "p1", userId: "userA", imageURL: "https://...", thumbnailURL: "https://...", text: "test", createdAt: (timestamp), updatedAt: (timestamp), expiresAt: (timestamp), isExpired: false, isHidden: false }`
- 期待結果: **許可**
- 検証内容: T14 実装後の `PostService.createPost`（`isHidden: false` を書き込む）が引き続き動作することを確認する。

### 6-2. isHidden フィールドを省略した投稿作成 → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/posts/{任意のドキュメントID}`
- 送信データ: `{ postId: "p2", userId: "userA", imageURL: "https://...", thumbnailURL: "https://...", text: "test", createdAt: (timestamp), updatedAt: (timestamp), expiresAt: (timestamp), isExpired: false }`（isHidden フィールドなし）
- 期待結果: **拒否**
- 検証内容: `request.resource.data.isHidden == false` の評価がフィールド未定義で失敗し、isHidden を省略した投稿作成が拒否されることを確認する。

### 6-3. isHidden: true を指定した投稿作成（自己での最初からの隠蔽） → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/posts/{任意のドキュメントID}`
- 送信データ: `{ postId: "p3", userId: "userA", ..., isHidden: true }`
- 期待結果: **拒否**
- 検証内容: クライアントが最初から `isHidden: true` で投稿を作成することはできないことを確認する（`isHidden` は運営専用フラグであるという原則の入口側の検証）。

### 6-4. 他人になりすました投稿作成（userId ≠ 自分） → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `create`
- パス: `/posts/{任意のドキュメントID}`
- 送信データ: `{ postId: "p4", userId: "userA", ..., isHidden: false }`
- 期待結果: **拒否**
- 検証内容: `request.auth.uid == request.resource.data.userId` により、isHidden 条件とは独立して、他人になりすました投稿作成が引き続き拒否されることを確認する。

### 6-5. 投稿者本人による、isHidden以外のフィールド更新（isHiddenは変更なし） → 許可されるか

- 認証 UID: `userA`
- 操作種別: `update`
- パス: `/posts/p1`
- 既存ドキュメント: `{ userId: "userA", text: "元のテキスト", isHidden: false, ... }`
- 送信データ: `{ userId: "userA", text: "更新後のテキスト", isHidden: false, ... }`
- 期待結果: **許可**
- 検証内容: バックフィル済みの既存ドキュメントに対して、isHidden を変更しない限り投稿者本人による更新が引き続き許可されることを確認する。

### 6-6. 投稿者本人による isHidden の自己変更（true への変更） → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `update`
- パス: `/posts/p1`
- 既存ドキュメント: `{ userId: "userA", text: "元のテキスト", isHidden: false, ... }`
- 送信データ: `{ userId: "userA", text: "元のテキスト", isHidden: true, ... }`
- 期待結果: **拒否**
- 検証内容: `request.resource.data.isHidden == resource.data.isHidden` により、投稿者自身が isHidden を書き換えることはできないことを確認する。

### 6-7. 投稿者本人による isHidden の自己解除（true → false への変更） → 拒否されるか

- 認証 UID: `userA`
- 操作種別: `update`
- パス: `/posts/p1`
- 既存ドキュメント: `{ userId: "userA", text: "元のテキスト", isHidden: true, ... }`（運営がコンソールで非表示化した想定）
- 送信データ: `{ userId: "userA", text: "元のテキスト", isHidden: false, ... }`
- 期待結果: **拒否**
- 検証内容: 運営が非表示化した投稿を、投稿者が API 直叩きで自己解除できないことを確認する（T14 の isHidden 条項の主目的）。

### 6-8. isHidden: true の投稿の読み取り → 許可されるか（既知の割り切り）

- 認証 UID: `userB`（投稿者本人でなくてもよい）
- 操作種別: `get`（読み取り）
- パス: `/posts/{isHidden: true の投稿ID}`
- 期待結果: **許可**
- 検証内容: posts の read ルールは isHidden を条件にしていない（`allow read: if signedIn()` のまま）ため、ドキュメントIDを直接指定した取得は isHidden の値に関わらず可能であることを確認する。タイムライン・プロフィール・ウィジェットからの除外は `whereField("isHidden", isEqualTo: false)` というアプリ側のクエリ条件で行っており、ルールレベルでの読み取り遮断ではない点を把握しておく（既知の割り切り。将来的な改善余地）。

---

## 7. followRequests（read ルールと list クエリ制約の整合）

> 補足: これらは Rules Playground の単一パス get/create では再現しにくく（特に list はクエリ
> 制約に基づく許可判定を伴う）、エミュレータ（`@firebase/rules-unit-testing`）での list クエリ
> テストを推奨する。権限エラー2がすり抜けた主因はここ（list 制約の検証欠如）にある。

### 7-1. 自分宛の pending リクエスト一覧（targetId == 自分） → 許可されるか

- 認証 UID: `userA`
- 操作種別: `list`（クエリ）
- クエリ: `followRequests where targetId == "userA" and status == "pending"`
- 期待結果: **許可**
- 検証内容: 通知画面（NotificationsViewModel）の用途。read ルール `resource.data.targetId == request.auth.uid` がクエリ制約で保証されるため許可される。

### 7-2. 相手宛の pending リクエスト一覧（targetId == 相手） → 拒否される（権限エラー2の原因）

- 認証 UID: `userA`
- 操作種別: `list`（クエリ）
- クエリ: `followRequests where targetId == "userB" and status == "pending"`
- 期待結果: **拒否**
- 検証内容: 「自分が相手に送ったリクエストがあるか」を確認するために相手宛の全リクエストを引こうとすると、`requesterId` が制約されないため read ルール（requester または target 本人のみ）を満たせず拒否される。**修正はクライアント側で行い、`requesterId == 自分` を制約に含むクエリ（`checkExistingRequest`）に置き換える。`firestore.rules` は変更しない。**

### 7-3. 自分が送信したリクエストのクエリ（requesterId == 自分） → 許可されるか

- 認証 UID: `userA`
- 操作種別: `list`（クエリ）
- クエリ: `followRequests where requesterId == "userA" and targetId == "userB" and status == "pending"`
- 期待結果: **許可**
- 検証内容: 7-2 の正しい代替。`resource.data.requesterId == request.auth.uid` がクエリ制約で保証されるため許可される。equality のみ（orderBy なし）のため複合インデックス不要。

### 7-4. 存在しない followRequests ドキュメントへの get → 拒否される（4-8 と同種の地雷）

- 認証 UID: `userA`
- 操作種別: `get`（読み取り）
- パス: `/followRequests/userA_userB`
- 既存ドキュメント: **なし（空欄のまま）**
- 期待結果: **拒否**
- 検証内容: blocks と同様、read ルールが `resource.data` を参照するため非存在ドキュメントの get は拒否される。フォロー状態チェックを複合ID直引きの get で実装したくなった場合の注意点。存在確認は 7-3 の list クエリで行うこと。

---

## 実行後のチェックリスト

- [ ] 1-1 〜 1-6（users カウンタ更新）
- [ ] 2-1 〜 2-2（follows 直接作成）
- [ ] 3-1 〜 3-3（users 削除）
- [ ] 4-1 〜 4-8（blocks。4-8 は非存在ドキュメントへの get ＝権限エラー1の再現）
- [ ] 5-1 〜 5-4（reports）
- [ ] 6-1 〜 6-8（posts / isHidden 有効化の確認。既存 posts のバックフィル完了が前提）
- [ ] 7-1 〜 7-4（followRequests の read ルールと list クエリ制約。7-2 は権限エラー2の再現）

すべて期待結果と一致すればコンソールへの本適用に進んでください。想定と異なる結果が出た場合は、該当ケースの番号とPlaygroundの実際の結果（許可/拒否とエラーメッセージ）を控えて共有してください。
