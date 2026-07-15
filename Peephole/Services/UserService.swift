//
//  UserService.swift
//  Peephole
//
//  Firestoreのusersコレクションに対するCRUD操作
//  ユーザープロフィールの作成、取得、更新を担当
//

import Foundation
import FirebaseFirestore

// MARK: - User Model (Firestore用)
struct FirestoreUser: Codable, Identifiable {
    let userId: String
    var username: String
    var displayName: String
    var email: String
    var profileImageURL: String?
    var bio: String?
    var isPrivate: Bool
    var followersCount: Int
    var followingCount: Int
    var postsCount: Int
    let createdAt: Date
    var updatedAt: Date
    var agreedTermsVersion: String?
    var agreedTermsAt: Date?

    // Identifiable準拠のため、userIdをidとして使用
    var id: String { userId }

    // Models.swift の PeepholeUser に変換
    func toPeepholeUser() -> PeepholeUser {
        return PeepholeUser(
            id: userId,
            username: username,
            displayName: displayName,
            profileImageURL: profileImageURL
        )
    }
}

enum UserServiceError: LocalizedError {
    case userNotFound
    case usernameAlreadyExists
    case invalidUsername
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .userNotFound:
            return "ユーザーが見つかりません"
        case .usernameAlreadyExists:
            return "このユーザー名は既に使用されています"
        case .invalidUsername:
            return "ユーザー名は3文字以上、英数字とアンダースコアのみ使用できます"
        case .unknown(let message):
            return "エラーが発生しました: \(message)"
        }
    }
}

class UserService {

    // MARK: - Singleton
    static let shared = UserService()

    private let db = FirebaseManager.shared.db
    private let usersCollection = FirebaseManager.shared.usersCollection

    private init() {}

    // MARK: - Create User Profile
    /// 新規ユーザープロフィールを作成
    /// - Parameters:
    ///   - userId: Firebase AuthのUID
    ///   - username: ユーザー名（@username）
    ///   - displayName: 表示名
    ///   - email: メールアドレス
    func createUserProfile(
        userId: String,
        username: String,
        displayName: String,
        email: String
    ) async throws {
        print("🔵 [USER] createUserProfile started")
        print("   - userId: \(userId)")
        print("   - username: \(username)")
        print("   - displayName: \(displayName)")
        print("   - email: \(email)")

        // ユーザー名のバリデーション
        print("🔵 [USER] Validating username...")
        guard isValidUsername(username) else {
            print("❌ [USER] Invalid username format")
            throw UserServiceError.invalidUsername
        }
        print("✅ [USER] Username validation passed")

        // ユーザー名の重複チェック
        print("🔵 [USER] Checking username duplicate...")
        do {
            let isDuplicate = try await checkUsernameDuplicate(username)
            if isDuplicate {
                print("❌ [USER] Username already exists")
                throw UserServiceError.usernameAlreadyExists
            }
            print("✅ [USER] Username is available")
        } catch let error as UserServiceError {
            throw error
        } catch let error as NSError {
            print("❌ [USER] Username duplicate check failed")
            print("   - Error code: \(error.code)")
            print("   - Error domain: \(error.domain)")
            print("   - Error description: \(error.localizedDescription)")
            print("   - Error userInfo: \(error.userInfo)")
            throw UserServiceError.unknown(error.localizedDescription)
        }

        let user = FirestoreUser(
            userId: userId,
            username: username,
            displayName: displayName,
            email: email,
            profileImageURL: nil,
            bio: nil,
            isPrivate: true, // 初期実装ではすべて鍵アカウント
            followersCount: 0,
            followingCount: 0,
            postsCount: 0,
            createdAt: Date(),
            updatedAt: Date(),
            agreedTermsVersion: LegalTexts.currentTermsVersion,
            agreedTermsAt: Date()
        )

        print("🔵 [USER] Saving user profile to Firestore...")
        do {
            try usersCollection.document(userId).setData(from: user)
            print("✅ [USER] User profile created successfully: \(userId)")
        } catch let error as NSError {
            print("❌ [USER] Failed to save user profile to Firestore")
            print("   - Error code: \(error.code)")
            print("   - Error domain: \(error.domain)")
            print("   - Error description: \(error.localizedDescription)")
            print("   - Error userInfo: \(error.userInfo)")
            throw UserServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get User Profile
    /// ユーザープロフィールを取得
    /// - Parameter userId: ユーザーID
    /// - Returns: FirestoreUser
    func getUserProfile(userId: String) async throws -> FirestoreUser {
        print("🔵 [USER] getUserProfile() started for userId: \(userId)")
        do {
            let document = try await usersCollection.document(userId).getDocument()
            print("🔵 [USER] Document fetched - exists: \(document.exists)")

            guard document.exists else {
                print("❌ [USER] User document not found in Firestore")
                throw UserServiceError.userNotFound
            }

            let user = try document.data(as: FirestoreUser.self)
            print("✅ [USER] User profile fetched successfully: @\(user.username)")
            return user
        } catch let error as UserServiceError {
            print("❌ [USER] getUserProfile failed with UserServiceError")
            print("   - Error description: \(error.errorDescription ?? "nil")")
            throw error
        } catch let error as NSError {
            print("❌ [USER] getUserProfile failed with NSError")
            print("   - Error code: \(error.code)")
            print("   - Error domain: \(error.domain)")
            print("   - Error description: \(error.localizedDescription)")
            print("   - Error userInfo: \(error.userInfo)")
            throw UserServiceError.unknown(error.localizedDescription)
        } catch {
            print("❌ [USER] getUserProfile failed with unknown error")
            print("   - Error: \(error)")
            throw UserServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Update User Profile
    /// ユーザープロフィールを更新
    /// - Parameters:
    ///   - userId: ユーザーID
    ///   - displayName: 表示名（オプション）
    ///   - bio: 自己紹介（オプション）
    ///   - profileImageURL: プロフィール画像URL（オプション）
    func updateUserProfile(
        userId: String,
        displayName: String? = nil,
        bio: String? = nil,
        profileImageURL: String? = nil
    ) async throws {
        var updateData: [String: Any] = [
            "updatedAt": FieldValue.serverTimestamp()
        ]

        if let displayName = displayName {
            updateData["displayName"] = displayName
        }
        if let bio = bio {
            updateData["bio"] = bio
        }
        if let profileImageURL = profileImageURL {
            updateData["profileImageURL"] = profileImageURL
        }

        do {
            try await usersCollection.document(userId).updateData(updateData)
            print("✅ User profile updated: \(userId)")
        } catch {
            throw UserServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Update Terms Agreement
    /// 規約への同意記録を更新（既存ユーザーの再同意用）
    /// - Parameters:
    ///   - userId: ユーザーID
    ///   - version: 同意した規約バージョン
    func updateTermsAgreement(userId: String, version: String) async throws {
        let updateData: [String: Any] = [
            "agreedTermsVersion": version,
            "agreedTermsAt": FieldValue.serverTimestamp()
        ]

        do {
            try await usersCollection.document(userId).updateData(updateData)
            print("✅ Terms agreement updated: \(userId) -> \(version)")
        } catch {
            throw UserServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Update Username
    /// ユーザー名を更新
    /// - Parameters:
    ///   - userId: ユーザーID
    ///   - newUsername: 新しいユーザー名
    func updateUsername(userId: String, newUsername: String) async throws {
        // ユーザー名のバリデーション
        guard isValidUsername(newUsername) else {
            throw UserServiceError.invalidUsername
        }

        // 現在のユーザー名を取得
        let currentUser = try await getUserProfile(userId: userId)

        // 同じユーザー名ならスキップ
        if currentUser.username == newUsername {
            return
        }

        // 重複チェック
        let isDuplicate = try await checkUsernameDuplicate(newUsername)
        if isDuplicate {
            throw UserServiceError.usernameAlreadyExists
        }

        // 更新
        do {
            try await usersCollection.document(userId).updateData([
                "username": newUsername,
                "updatedAt": FieldValue.serverTimestamp()
            ])
            print("✅ Username updated: \(newUsername)")
        } catch {
            throw UserServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Search Users
    /// ユーザー名で検索
    /// - Parameter query: 検索クエリ
    /// - Returns: 検索結果のユーザー一覧
    func searchUsers(query: String) async throws -> [FirestoreUser] {
        guard !query.isEmpty else { return [] }

        do {
            // ユーザー名の前方一致検索
            // Firestoreの制限により、部分一致検索は困難なため、前方一致のみ
            let querySnapshot = try await usersCollection
                .whereField("username", isGreaterThanOrEqualTo: query)
                .whereField("username", isLessThan: query + "\u{f8ff}") // Unicode最大値
                .limit(to: 20)
                .getDocuments()

            let users = try querySnapshot.documents.compactMap { document in
                try document.data(as: FirestoreUser.self)
            }

            return users
        } catch {
            throw UserServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Increment Stats
    /// 統計情報を増減（フォロー数、投稿数など）
    /// - Parameters:
    ///   - userId: ユーザーID
    ///   - field: フィールド名（"followersCount", "followingCount", "postsCount"）
    ///   - increment: 増減値（正の数で増加、負の数で減少）
    func incrementUserStats(userId: String, field: String, by increment: Int) async throws {
        do {
            try await usersCollection.document(userId).updateData([
                field: FieldValue.increment(Int64(increment))
            ])
            print("✅ User stats updated: \(field) by \(increment)")
        } catch {
            throw UserServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Private Helpers
    /// ユーザー名の重複チェック
    private func checkUsernameDuplicate(_ username: String) async throws -> Bool {
        let querySnapshot = try await usersCollection
            .whereField("username", isEqualTo: username)
            .limit(to: 1)
            .getDocuments()

        return !querySnapshot.documents.isEmpty
    }

    /// ユーザー名のバリデーション
    /// - 3文字以上
    /// - 英数字とアンダースコアのみ
    private func isValidUsername(_ username: String) -> Bool {
        let usernameRegex = "^[a-zA-Z0-9_]{3,}$"
        let predicate = NSPredicate(format: "SELF MATCHES %@", usernameRegex)
        return predicate.evaluate(with: username)
    }
}
