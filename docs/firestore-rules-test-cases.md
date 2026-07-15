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

## 6. posts（isHidden 条件が無効化されていることの確認）

### 6-1. isHidden フィールドを含まない投稿作成 → 許可されるか

- 認証 UID: `userA`
- 操作種別: `create`
- パス: `/posts/{任意のドキュメントID}`
- 送信データ: `{ postId: "p1", userId: "userA", imageURL: "https://...", thumbnailURL: "https://...", text: "test", createdAt: (timestamp), updatedAt: (timestamp), expiresAt: (timestamp), isExpired: false }`（isHidden フィールドなし）
- 期待結果: **許可**
- 検証内容: T18 時点では posts.isHidden の強制が無効化されているため、既存の PostService.createPost（isHidden を書き込まない）が引き続き動作することを確認する。T14 実装後に isHidden 条件を有効化した際は、このケースが拒否に変わるはずなので、その回帰確認にも再利用できる。

### 6-2. 他人になりすました投稿作成（userId ≠ 自分） → 拒否されるか

- 認証 UID: `userB`
- 操作種別: `create`
- パス: `/posts/{任意のドキュメントID}`
- 送信データ: `{ postId: "p2", userId: "userA", ... }`
- 期待結果: **拒否**
- 検証内容: `request.auth.uid == request.resource.data.userId` により、他人になりすました投稿作成ができないことを確認する（isHidden 条件とは独立して機能していることの確認）。

### 6-3. 投稿者本人による投稿テキストの更新 → 許可されるか

- 認証 UID: `userA`
- 操作種別: `update`
- パス: `/posts/p1`
- 既存ドキュメント: `{ userId: "userA", text: "元のテキスト", ... }`（isHidden フィールドなし）
- 送信データ: `{ userId: "userA", text: "更新後のテキスト", ... }`
- 期待結果: **許可**
- 検証内容: isHidden フィールドが存在しない既存ドキュメントに対しても、投稿者本人による更新がエラーなく許可されることを確認する（isHidden 条件を無効化した理由の裏付け：もし有効化していた場合、フィールド未定義参照でここが拒否されてしまう）。

---

## 実行後のチェックリスト

- [ ] 1-1 〜 1-6（users カウンタ更新）
- [ ] 2-1 〜 2-2（follows 直接作成）
- [ ] 3-1 〜 3-3（users 削除）
- [ ] 4-1 〜 4-7（blocks）
- [ ] 5-1 〜 5-4（reports）
- [ ] 6-1 〜 6-3（posts / isHidden 無効化の確認）

すべて期待結果と一致すればコンソールへの本適用に進んでください。想定と異なる結果が出た場合は、該当ケースの番号とPlaygroundの実際の結果（許可/拒否とエラーメッセージ）を控えて共有してください。
