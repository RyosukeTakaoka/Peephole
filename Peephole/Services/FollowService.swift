//
//  FollowService.swift
//  Peephole
//
//  フォロー機能のビジネスロジック
//  フォローリクエスト送信、承認、拒否、フォロー解除を担当
//  データの一貫性を保つため、トランザクション処理を使用
//

import Foundation
import FirebaseFirestore

// MARK: - Follow Request Model
struct FirestoreFollowRequest: Codable, Identifiable {
    let requestId: String
    let requesterId: String
    let targetId: String
    var status: FollowRequestStatus
    let createdAt: Date
    var respondedAt: Date?

    // Identifiable準拠のため、requestIdをidとして使用
    var id: String { requestId }

    enum FollowRequestStatus: String, Codable {
        case pending
        case accepted
        case rejected
    }
}

// MARK: - Follow Model
struct FirestoreFollow: Codable {
    let followId: String
    let followerId: String // フォローしている人
    let followingId: String // フォローされている人
    let createdAt: Date
}

enum FollowServiceError: LocalizedError {
    case alreadyFollowing
    case requestAlreadyExists
    case requestNotFound
    case cannotFollowSelf
    case unauthorizedOperation
    case userNotFound
    case transactionFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .alreadyFollowing:
            return "既にフォローしています"
        case .requestAlreadyExists:
            return "既にフォローリクエストを送信しています"
        case .requestNotFound:
            return "フォローリクエストが見つかりません"
        case .cannotFollowSelf:
            return "自分自身をフォローすることはできません"
        case .unauthorizedOperation:
            return "この操作を実行する権限がありません"
        case .userNotFound:
            return "ユーザーが見つかりません"
        case .transactionFailed(let message):
            return "トランザクションエラー: \(message)"
        case .unknown(let message):
            return "エラーが発生しました: \(message)"
        }
    }
}

class FollowService {

    // MARK: - Singleton
    static let shared = FollowService()

    private let db = FirebaseManager.shared.db
    private let followsCollection = FirebaseManager.shared.followsCollection
    private let followRequestsCollection = FirebaseManager.shared.followRequestsCollection
    private let usersCollection = FirebaseManager.shared.usersCollection

    private init() {}

    // MARK: - Send Follow Request
    /// フォローリクエストを送信
    /// - Parameters:
    ///   - requesterId: リクエスト送信者のUID
    ///   - targetId: リクエスト受信者のUID
    func sendFollowRequest(from requesterId: String, to targetId: String) async throws {
        print("🔵 [FOLLOW] フォローリクエスト送信を開始: \(requesterId) → \(targetId)")

        // 自分自身をフォローできないチェック
        guard requesterId != targetId else {
            print("❌ [FOLLOW] 自分自身へのフォローリクエストは不可")
            throw FollowServiceError.cannotFollowSelf
        }

        // 既にフォロー関係が存在するかチェック
        let isFollowing = try await checkIfFollowing(followerId: requesterId, followingId: targetId)
        if isFollowing {
            print("❌ [FOLLOW] 既にフォロー済み: \(requesterId) → \(targetId)")
            throw FollowServiceError.alreadyFollowing
        }

        // 既にリクエストが存在するかチェック
        let hasPending = try await hasPendingRequest(from: requesterId, to: targetId)
        if hasPending {
            print("❌ [FOLLOW] 既にリクエスト送信済み: \(requesterId) → \(targetId)")
            throw FollowServiceError.requestAlreadyExists
        }

        // フォローリクエストを作成
        let newRequestRef = followRequestsCollection.document()
        let request = FirestoreFollowRequest(
            requestId: newRequestRef.documentID,
            requesterId: requesterId,
            targetId: targetId,
            status: .pending,
            createdAt: Date(),
            respondedAt: nil
        )

        do {
            try newRequestRef.setData(from: request)
            print("✅ [FOLLOW] フォローリクエスト送信成功: \(requesterId) → \(targetId), requestId: \(newRequestRef.documentID)")
        } catch {
            print("❌ [FOLLOW] フォローリクエスト送信失敗: \(requesterId) → \(targetId), error: \(error)")
            throw FollowServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Approve Follow Request (トランザクション処理)
    /// フォローリクエストを承認
    /// データの一貫性を保つため、トランザクションを使用
    /// - Parameters:
    ///   - requestId: フォローリクエストID
    ///   - currentUserId: 承認を実行するユーザーID（権限チェック用）
    func approveFollowRequest(requestId: String, currentUserId: String) async throws {
        print("🔵 [FOLLOW] フォローリクエスト承認を開始: requestId=\(requestId), currentUserId=\(currentUserId)")
        do {
            try await db.runTransaction { (transaction, errorPointer) -> Any? in
                // 1. フォローリクエストを取得
                let requestRef = self.followRequestsCollection.document(requestId)
                let requestSnapshot: DocumentSnapshot
                do {
                    requestSnapshot = try transaction.getDocument(requestRef)
                } catch {
                    errorPointer?.pointee = NSError(
                        domain: "FollowService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "リクエストの取得に失敗"]
                    )
                    return nil
                }

                guard requestSnapshot.exists else {
                    errorPointer?.pointee = NSError(
                        domain: "FollowService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "リクエストが見つかりません"]
                    )
                    return nil
                }

                guard let requestData = try? requestSnapshot.data(as: FirestoreFollowRequest.self) else {
                    errorPointer?.pointee = NSError(
                        domain: "FollowService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "リクエストデータが不正です"]
                    )
                    return nil
                }

                // 権限チェック：リクエストの受信者のみが承認できる
                guard requestData.targetId == currentUserId else {
                    errorPointer?.pointee = NSError(
                        domain: "FollowService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "権限がありません"]
                    )
                    return nil
                }

                // ステータスチェック
                guard requestData.status == .pending else {
                    errorPointer?.pointee = NSError(
                        domain: "FollowService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "既に処理済みです"]
                    )
                    return nil
                }

                // 2. followsコレクションに新しい関係を追加
                let newFollowRef = self.followsCollection.document()
                let follow = FirestoreFollow(
                    followId: newFollowRef.documentID,
                    followerId: requestData.requesterId,
                    followingId: requestData.targetId,
                    createdAt: Date()
                )

                do {
                    try transaction.setData(from: follow, forDocument: newFollowRef)
                } catch {
                    errorPointer?.pointee = NSError(
                        domain: "FollowService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "フォロー関係の作成に失敗"]
                    )
                    return nil
                }

                // 3. リクエスト送信者のfollowingCountを+1
                let requesterRef = self.usersCollection.document(requestData.requesterId)
                transaction.updateData([
                    "followingCount": FieldValue.increment(Int64(1))
                ], forDocument: requesterRef)

                // 4. リクエスト受信者のfollowersCountを+1
                let targetRef = self.usersCollection.document(requestData.targetId)
                transaction.updateData([
                    "followersCount": FieldValue.increment(Int64(1))
                ], forDocument: targetRef)

                // 5. フォローリクエストを削除
                transaction.deleteDocument(requestRef)

                return nil
            }

            print("✅ [FOLLOW] フォローリクエスト承認成功: \(requestId)")

        } catch {
            print("❌ [FOLLOW] フォローリクエスト承認失敗: \(requestId), error: \(error)")
            throw FollowServiceError.transactionFailed(error.localizedDescription)
        }
    }

    // MARK: - Reject Follow Request
    /// フォローリクエストを拒否
    /// - Parameters:
    ///   - requestId: フォローリクエストID
    ///   - currentUserId: 拒否を実行するユーザーID（権限チェック用）
    func rejectFollowRequest(requestId: String, currentUserId: String) async throws {
        print("🔵 [FOLLOW] フォローリクエスト拒否を開始: requestId=\(requestId), currentUserId=\(currentUserId)")

        // リクエストを取得
        let requestSnapshot = try await followRequestsCollection.document(requestId).getDocument()

        guard requestSnapshot.exists else {
            print("❌ [FOLLOW] リクエストが見つかりません: \(requestId)")
            throw FollowServiceError.requestNotFound
        }

        guard let request = try? requestSnapshot.data(as: FirestoreFollowRequest.self) else {
            print("❌ [FOLLOW] リクエストデータが不正です: \(requestId)")
            throw FollowServiceError.unknown("リクエストデータが不正です")
        }

        // 権限チェック
        guard request.targetId == currentUserId else {
            print("❌ [FOLLOW] 権限がありません: requestId=\(requestId), targetId=\(request.targetId), currentUserId=\(currentUserId)")
            throw FollowServiceError.unauthorizedOperation
        }

        // リクエストを削除
        do {
            try await followRequestsCollection.document(requestId).delete()
            print("✅ [FOLLOW] フォローリクエスト拒否成功: requestId=\(requestId), requesterId=\(request.requesterId)")
        } catch {
            print("❌ [FOLLOW] フォローリクエスト拒否失敗: \(requestId), error: \(error)")
            throw FollowServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Unfollow (トランザクション処理)
    /// フォローを解除
    /// - Parameters:
    ///   - followerId: フォローしている人のUID
    ///   - followingId: フォローされている人のUID
    func unfollow(followerId: String, followingId: String) async throws {
        // フォロー関係を検索
        let querySnapshot = try await followsCollection
            .whereField("followerId", isEqualTo: followerId)
            .whereField("followingId", isEqualTo: followingId)
            .limit(to: 1)
            .getDocuments()

        guard let followDoc = querySnapshot.documents.first else {
            throw FollowServiceError.unknown("フォロー関係が見つかりません")
        }

        let followId = followDoc.documentID

        // トランザクションで処理
        do {
            try await db.runTransaction { (transaction, errorPointer) -> Any? in
                // 1. フォロー関係を削除
                let followRef = self.followsCollection.document(followId)
                transaction.deleteDocument(followRef)

                // 2. フォローしている人のfollowingCountを-1
                let followerRef = self.usersCollection.document(followerId)
                transaction.updateData([
                    "followingCount": FieldValue.increment(Int64(-1))
                ], forDocument: followerRef)

                // 3. フォローされている人のfollowersCountを-1
                let followingRef = self.usersCollection.document(followingId)
                transaction.updateData([
                    "followersCount": FieldValue.increment(Int64(-1))
                ], forDocument: followingRef)

                return nil
            }

            print("✅ Unfollowed: \(followerId) unfollowed \(followingId)")

        } catch {
            throw FollowServiceError.transactionFailed(error.localizedDescription)
        }
    }

    // MARK: - Get Following List
    /// フォロー中のユーザーIDリストを取得
    /// - Parameter userId: ユーザーID
    /// - Returns: フォロー中のユーザーIDリスト
    func getFollowingIds(userId: String) async throws -> [String] {
        do {
            let querySnapshot = try await followsCollection
                .whereField("followerId", isEqualTo: userId)
                .getDocuments()

            let followingIds = querySnapshot.documents.compactMap { document in
                try? document.data(as: FirestoreFollow.self).followingId
            }

            return followingIds
        } catch {
            throw FollowServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Followers List
    /// フォロワーのユーザーIDリストを取得
    /// - Parameter userId: ユーザーID
    /// - Returns: フォロワーのユーザーIDリスト
    func getFollowerIds(userId: String) async throws -> [String] {
        do {
            let querySnapshot = try await followsCollection
                .whereField("followingId", isEqualTo: userId)
                .getDocuments()

            let followerIds = querySnapshot.documents.compactMap { document in
                try? document.data(as: FirestoreFollow.self).followerId
            }

            return followerIds
        } catch {
            throw FollowServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Pending Follow Requests
    /// 自分宛のフォローリクエスト一覧を取得
    /// - Parameter userId: ユーザーID
    /// - Returns: フォローリクエスト一覧
    func getPendingFollowRequests(targetId: String) async throws -> [FirestoreFollowRequest] {
        print("🔵 [FOLLOW] getPendingFollowRequests: targetId=\(targetId), status=pending")
        do {
            let querySnapshot = try await followRequestsCollection
                .whereField("targetId", isEqualTo: targetId)
                .whereField("status", isEqualTo: "pending")
                .order(by: "createdAt", descending: true)
                .getDocuments()

            let requests = try querySnapshot.documents.compactMap { document in
                try document.data(as: FirestoreFollowRequest.self)
            }
            print("✅ [FOLLOW] getPendingFollowRequests取得完了: \(requests.count)件")

            return requests
        } catch {
            throw FollowServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Cancel Follow Request
    /// 送信したフォローリクエストをキャンセル
    /// - Parameters:
    ///   - requesterId: リクエスト送信者のUID
    ///   - targetId: リクエスト受信者のUID
    func cancelFollowRequest(requesterId: String, targetId: String) async throws {
        // リクエストを検索
        let querySnapshot = try await followRequestsCollection
            .whereField("requesterId", isEqualTo: requesterId)
            .whereField("targetId", isEqualTo: targetId)
            .whereField("status", isEqualTo: "pending")
            .limit(to: 1)
            .getDocuments()

        guard let requestDoc = querySnapshot.documents.first else {
            throw FollowServiceError.requestNotFound
        }

        // 削除
        do {
            try await followRequestsCollection.document(requestDoc.documentID).delete()
            print("✅ Follow request cancelled: \(requesterId) → \(targetId)")
        } catch {
            throw FollowServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Check Follow Status
    /// フォロー状態を確認
    /// - Parameters:
    ///   - followerId: フォローしている人のUID
    ///   - followingId: フォローされている人のUID
    /// - Returns: フォロー中ならtrue
    func checkIfFollowing(followerId: String, followingId: String) async throws -> Bool {
        let querySnapshot = try await followsCollection
            .whereField("followerId", isEqualTo: followerId)
            .whereField("followingId", isEqualTo: followingId)
            .limit(to: 1)
            .getDocuments()

        return !querySnapshot.documents.isEmpty
    }

    // MARK: - Has Pending Request
    /// 自分から相手への保留中リクエストが存在するか
    /// - Note: セキュリティルール上「自分が当事者のリクエストのみ読める」ため、
    ///   このメソッドのように requesterId==自分 のクエリを使うこと（targetId==相手 の全件取得は権限エラーになる）
    func hasPendingRequest(from requesterId: String, to targetId: String) async throws -> Bool {
        let querySnapshot = try await followRequestsCollection
            .whereField("requesterId", isEqualTo: requesterId)
            .whereField("targetId", isEqualTo: targetId)
            .whereField("status", isEqualTo: "pending")
            .limit(to: 1)
            .getDocuments()

        let result = !querySnapshot.documents.isEmpty
        print("🔵 [FOLLOW] hasPendingRequest: \(requesterId) → \(targetId) = \(result)")
        return result
    }
}
