//
//  PostService.swift
//  Peephole
//
//  Firestoreのpostsコレクションに対するCRUD操作
//  投稿の作成、取得、削除を担当
//

import Foundation
import FirebaseFirestore

// MARK: - Firestore Post Model
struct FirestorePost: Codable, Identifiable {
    let postId: String
    let userId: String
    let imageURL: String
    let thumbnailURL: String
    let text: String
    let song: FirestoreSong?
    let userName: String
    let userDisplayName: String
    let userProfileImageURL: String?
    let createdAt: Date
    let updatedAt: Date
    let expiresAt: Date?
    let isExpired: Bool
    let isHidden: Bool

    // Identifiable準拠のため、postIdをidとして使用
    var id: String { postId }

    // Models.swift の Post に変換
    func toPost() -> Post {
        return Post(
            id: postId,
            userId: userId,
            imageURL: thumbnailURL, // ウィジェットではサムネイルを使用
            text: text,
            song: song?.toSong(),
            createdAt: createdAt,
            userName: userName,
            userDisplayName: userDisplayName,
            userProfileImageURL: userProfileImageURL
        )
    }
}

struct FirestoreSong: Codable {
    let title: String
    let artist: String
    let spotifyId: String?

    func toSong() -> Song {
        return Song(title: title, artist: artist)
    }
}

enum PostServiceError: LocalizedError {
    case postNotFound
    case unauthorizedAccess
    case invalidData
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .postNotFound:
            return "投稿が見つかりません"
        case .unauthorizedAccess:
            return "この操作を実行する権限がありません"
        case .invalidData:
            return "投稿データが不正です"
        case .unknown(let message):
            return "エラーが発生しました: \(message)"
        }
    }
}

class PostService {

    // MARK: - Singleton
    static let shared = PostService()

    private let db = FirebaseManager.shared.db
    private let postsCollection = FirebaseManager.shared.postsCollection

    private init() {}

    // MARK: - Create Post
    /// 新しい投稿を作成
    /// - Parameters:
    ///   - userId: 投稿者のユーザーID
    ///   - imageURL: Cloudinaryの画像URL（オリジナル）
    ///   - text: 投稿テキスト
    ///   - song: 曲情報（オプション）
    ///   - userInfo: ユーザー情報（非正規化用）
    /// - Returns: 作成された投稿のID
    func createPost(
        userId: String,
        imageURL: String,
        text: String,
        song: FirestoreSong?,
        userInfo: (username: String, displayName: String, profileImageURL: String?)
    ) async throws -> String {
        // サムネイルURLを生成
        let thumbnailURL = CloudinaryService.generateThumbnailURL(from: imageURL)

        // 新しい投稿ドキュメントのIDを生成
        let newPostRef = postsCollection.document()

        let post = FirestorePost(
            postId: newPostRef.documentID,
            userId: userId,
            imageURL: imageURL,
            thumbnailURL: thumbnailURL,
            text: text,
            song: song,
            userName: userInfo.username,
            userDisplayName: userInfo.displayName,
            userProfileImageURL: userInfo.profileImageURL,
            createdAt: Date(),
            updatedAt: Date(),
            expiresAt: nil, // 将来的に24時間後の日時を設定
            isExpired: false,
            isHidden: false
        )

        do {
            try newPostRef.setData(from: post)

            // ユーザーの投稿数をインクリメント
            try await UserService.shared.incrementUserStats(
                userId: userId,
                field: "postsCount",
                by: 1
            )

            print("✅ Post created: \(newPostRef.documentID)")
            return newPostRef.documentID
        } catch {
            throw PostServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Post
    /// 投稿を取得
    /// - Parameter postId: 投稿ID
    /// - Returns: FirestorePost
    func getPost(postId: String) async throws -> FirestorePost {
        do {
            let document = try await postsCollection.document(postId).getDocument()

            guard document.exists else {
                throw PostServiceError.postNotFound
            }

            let post = try document.data(as: FirestorePost.self)
            return post
        } catch let error as PostServiceError {
            throw error
        } catch {
            throw PostServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get User Posts
    /// 特定ユーザーの投稿一覧を取得
    /// - Parameters:
    ///   - userId: ユーザーID
    ///   - limit: 取得件数
    /// - Returns: 投稿一覧
    func getUserPosts(userId: String, limit: Int = 20) async throws -> [FirestorePost] {
        do {
            let querySnapshot = try await postsCollection
                .whereField("userId", isEqualTo: userId)
                .whereField("isExpired", isEqualTo: false)
                .whereField("isHidden", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()

            let posts = try querySnapshot.documents.compactMap { document in
                try document.data(as: FirestorePost.self)
            }

            return posts
        } catch {
            throw PostServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Timeline Posts
    /// タイムライン用の投稿を取得（フォロー中のユーザーの投稿）
    /// - Parameters:
    ///   - userIds: フォロー中のユーザーIDリスト
    ///   - limit: 取得件数
    /// - Returns: 投稿一覧
    func getTimelinePosts(userIds: [String], limit: Int = 20) async throws -> [FirestorePost] {
        guard !userIds.isEmpty else { return [] }

        // Firestoreの制限: in演算子は最大10件まで
        let limitedUserIds = Array(userIds.prefix(10))

        do {
            let querySnapshot = try await postsCollection
                .whereField("userId", in: limitedUserIds)
                .whereField("isExpired", isEqualTo: false)
                .whereField("isHidden", isEqualTo: false)
                .order(by: "createdAt", descending: true)
                .limit(to: limit)
                .getDocuments()

            let posts = try querySnapshot.documents.compactMap { document in
                try document.data(as: FirestorePost.self)
            }

            return posts
        } catch {
            throw PostServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Widget Data
    /// ウィジェット用のデータを取得（最新の投稿を各ユーザーから1件ずつ）
    /// - Parameter userIds: フォロー中のユーザーIDリスト
    /// - Returns: ウィジェット用の投稿一覧
    func getWidgetPosts(userIds: [String]) async throws -> [FirestorePost] {
        guard !userIds.isEmpty else { return [] }

        var posts: [FirestorePost] = []

        // 各ユーザーの最新投稿を1件ずつ取得
        for userId in userIds {
            do {
                let userPosts = try await getUserPosts(userId: userId, limit: 1)
                if let latestPost = userPosts.first {
                    posts.append(latestPost)
                }
            } catch {
                // 個別のエラーは無視して続行
                print("⚠️ Failed to get posts for user \(userId): \(error)")
            }
        }

        // 作成日時でソート
        posts.sort { $0.createdAt > $1.createdAt }

        return posts
    }

    // MARK: - Delete Post
    /// 投稿を削除
    /// - Parameters:
    ///   - postId: 投稿ID
    ///   - userId: 削除を実行するユーザーID（権限チェック用）
    func deletePost(postId: String, userId: String) async throws {
        // 投稿を取得して権限チェック
        let post = try await getPost(postId: postId)

        guard post.userId == userId else {
            throw PostServiceError.unauthorizedAccess
        }

        do {
            try await postsCollection.document(postId).delete()

            // ユーザーの投稿数をデクリメント
            try await UserService.shared.incrementUserStats(
                userId: userId,
                field: "postsCount",
                by: -1
            )

            print("✅ Post deleted: \(postId)")
        } catch {
            throw PostServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Update Expired Status (将来的な拡張用)
    /// 投稿を期限切れにマーク
    /// - Parameter postId: 投稿ID
    func markAsExpired(postId: String) async throws {
        do {
            try await postsCollection.document(postId).updateData([
                "isExpired": true,
                "updatedAt": FieldValue.serverTimestamp()
            ])
            print("✅ Post marked as expired: \(postId)")
        } catch {
            throw PostServiceError.unknown(error.localizedDescription)
        }
    }
}
