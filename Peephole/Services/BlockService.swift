//
//  BlockService.swift
//  Peephole
//
//  ブロック機能のビジネスロジック
//  ブロック作成・解除、双方向のフォロー関係/リクエスト解消、フォローカウント調整を担当
//  データの一貫性を保つため、トランザクション処理を使用
//

import Foundation
import FirebaseFirestore

// MARK: - Block Model
struct FirestoreBlock: Codable, Identifiable {
    let blockId: String
    let blockerId: String  // ブロックした人
    let blockedId: String  // ブロックされた人
    let createdAt: Date
    var notified: Bool     // 開発者通知済みフラグ

    // Identifiable準拠のため、blockIdをidとして使用
    var id: String { blockId }
}

enum BlockServiceError: LocalizedError {
    case cannotBlockSelf
    case alreadyBlocked
    case blockNotFound
    case transactionFailed(String)
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .cannotBlockSelf:
            return "自分自身をブロックすることはできません"
        case .alreadyBlocked:
            return "既にブロックしています"
        case .blockNotFound:
            return "ブロック関係が見つかりません"
        case .transactionFailed(let message):
            return "トランザクションエラー: \(message)"
        case .unknown(let message):
            return "エラーが発生しました: \(message)"
        }
    }
}

class BlockService {

    // MARK: - Singleton
    static let shared = BlockService()

    private let db = FirebaseManager.shared.db
    private let blocksCollection = FirebaseManager.shared.blocksCollection
    private let followsCollection = FirebaseManager.shared.followsCollection
    private let followRequestsCollection = FirebaseManager.shared.followRequestsCollection
    private let usersCollection = FirebaseManager.shared.usersCollection

    private init() {}

    // MARK: - Block User (トランザクション処理)
    /// ユーザーをブロックする
    /// 双方向のフォロー関係・保留中フォローリクエストを解消し、フォローカウントを調整する
    /// - Parameters:
    ///   - blockerId: ブロックする人のUID
    ///   - blockedId: ブロックされる人のUID
    func blockUser(blockerId: String, blockedId: String) async throws {
        guard blockerId != blockedId else {
            throw BlockServiceError.cannotBlockSelf
        }

        let blockId = compositeBlockId(blockerId: blockerId, blockedId: blockedId)
        let blockRef = blocksCollection.document(blockId)

        // 二重ブロックチェック（list クエリで判定。存在しない blocks ドキュメントへの
        // point get は read ルールの resource.data 参照で拒否されるため使用しない）
        let alreadyBlockedIds = try await getBlockedIds(userId: blockerId)
        if alreadyBlockedIds.contains(blockedId) {
            throw BlockServiceError.alreadyBlocked
        }

        // 双方向のフォロー関係を事前に検索（トランザクション外）
        let forwardFollow = try await followsCollection
            .whereField("followerId", isEqualTo: blockerId)
            .whereField("followingId", isEqualTo: blockedId)
            .limit(to: 1)
            .getDocuments()

        let backwardFollow = try await followsCollection
            .whereField("followerId", isEqualTo: blockedId)
            .whereField("followingId", isEqualTo: blockerId)
            .limit(to: 1)
            .getDocuments()

        // 双方向の pending フォローリクエストを事前に検索（トランザクション外）
        let forwardRequests = try await followRequestsCollection
            .whereField("requesterId", isEqualTo: blockerId)
            .whereField("targetId", isEqualTo: blockedId)
            .whereField("status", isEqualTo: "pending")
            .getDocuments()

        let backwardRequests = try await followRequestsCollection
            .whereField("requesterId", isEqualTo: blockedId)
            .whereField("targetId", isEqualTo: blockerId)
            .whereField("status", isEqualTo: "pending")
            .getDocuments()

        do {
            try await db.runTransaction { (transaction, errorPointer) -> Any? in
                // 1. blocks ドキュメントを作成
                let block = FirestoreBlock(
                    blockId: blockId,
                    blockerId: blockerId,
                    blockedId: blockedId,
                    createdAt: Date(),
                    notified: false
                )
                do {
                    try transaction.setData(from: block, forDocument: blockRef)
                } catch {
                    errorPointer?.pointee = NSError(
                        domain: "BlockService",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "ブロックの作成に失敗"]
                    )
                    return nil
                }

                // 2. blocker → blocked のフォロー関係を削除し、カウントを調整
                if let followDoc = forwardFollow.documents.first {
                    transaction.deleteDocument(self.followsCollection.document(followDoc.documentID))
                    transaction.updateData(
                        ["followingCount": FieldValue.increment(Int64(-1))],
                        forDocument: self.usersCollection.document(blockerId)
                    )
                    transaction.updateData(
                        ["followersCount": FieldValue.increment(Int64(-1))],
                        forDocument: self.usersCollection.document(blockedId)
                    )
                }

                // 3. blocked → blocker のフォロー関係を削除し、カウントを調整
                if let followDoc = backwardFollow.documents.first {
                    transaction.deleteDocument(self.followsCollection.document(followDoc.documentID))
                    transaction.updateData(
                        ["followingCount": FieldValue.increment(Int64(-1))],
                        forDocument: self.usersCollection.document(blockedId)
                    )
                    transaction.updateData(
                        ["followersCount": FieldValue.increment(Int64(-1))],
                        forDocument: self.usersCollection.document(blockerId)
                    )
                }

                // 4. 双方向の pending フォローリクエストを削除
                for doc in forwardRequests.documents {
                    transaction.deleteDocument(self.followRequestsCollection.document(doc.documentID))
                }
                for doc in backwardRequests.documents {
                    transaction.deleteDocument(self.followRequestsCollection.document(doc.documentID))
                }

                return nil
            }

            print("✅ User blocked: \(blockerId) blocked \(blockedId)")

        } catch {
            throw BlockServiceError.transactionFailed(error.localizedDescription)
        }
    }

    // MARK: - Unblock User
    /// ブロックを解除する（フォロー関係は復元しない）
    /// - Parameters:
    ///   - blockerId: ブロックした人のUID
    ///   - blockedId: ブロックされた人のUID
    func unblockUser(blockerId: String, blockedId: String) async throws {
        let blockId = compositeBlockId(blockerId: blockerId, blockedId: blockedId)

        do {
            try await blocksCollection.document(blockId).delete()
            print("✅ User unblocked: \(blockerId) unblocked \(blockedId)")
        } catch {
            throw BlockServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Blocked Ids
    /// 自分がブロックしたユーザーIDの一覧を取得
    /// - Parameter userId: ユーザーID
    /// - Returns: ブロックしたユーザーIDのリスト
    func getBlockedIds(userId: String) async throws -> [String] {
        do {
            let querySnapshot = try await blocksCollection
                .whereField("blockerId", isEqualTo: userId)
                .getDocuments()

            let blockedIds = querySnapshot.documents.compactMap { document in
                try? document.data(as: FirestoreBlock.self).blockedId
            }

            return blockedIds
        } catch {
            throw BlockServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Blocker Ids
    /// 自分をブロックしているユーザーIDの一覧を取得
    /// - Parameter userId: ユーザーID
    /// - Returns: 自分をブロックしているユーザーIDのリスト
    func getBlockerIds(userId: String) async throws -> [String] {
        do {
            let querySnapshot = try await blocksCollection
                .whereField("blockedId", isEqualTo: userId)
                .getDocuments()

            let blockerIds = querySnapshot.documents.compactMap { document in
                try? document.data(as: FirestoreBlock.self).blockerId
            }

            return blockerIds
        } catch {
            throw BlockServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Is Blocked

    /// 2ユーザー間のいずれかの方向にブロック関係があるかを確認
    /// - Parameters:
    ///   - userId: ユーザーID
    ///   - otherUserId: 相手ユーザーID
    /// - Returns: どちらかの方向にブロックが存在すればtrue
    func isBlocked(between userId: String, and otherUserId: String) async throws -> Bool {
        // 存在しない blocks ドキュメントへの point get は read ルールの resource.data 参照で
        // 拒否されるため、単一フィールドの list クエリ（getBlockedIds / getBlockerIds）で判定する
        do {
            // userId → otherUserId 方向のブロック
            let blockedIds = try await getBlockedIds(userId: userId)
            if blockedIds.contains(otherUserId) {
                return true
            }

            // otherUserId → userId 方向のブロック
            let blockerIds = try await getBlockerIds(userId: userId)
            return blockerIds.contains(otherUserId)
        } catch {
            throw BlockServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Composite Block Id
    /// blocks コレクションの複合ID（"{blockerId}_{blockedId}"）を生成
    private func compositeBlockId(blockerId: String, blockedId: String) -> String {
        return "\(blockerId)_\(blockedId)"
    }
}
