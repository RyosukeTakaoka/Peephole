//
//  FirebaseManager.swift
//  Peephole
//
//  Firebase初期化と共通参照の管理
//

import Foundation
import FirebaseCore
import FirebaseAuth
import FirebaseFirestore

class FirebaseManager {

    // MARK: - Singleton
    static let shared = FirebaseManager()

    // MARK: - Firebase References
    let auth: Auth
    let db: Firestore

    // MARK: - Initialization
    private init() {
        print("🔵 [FIREBASE] FirebaseManager init() started")

        // デバッグ: GoogleService-Info.plistの読み込み確認
        if let filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let plist = NSDictionary(contentsOfFile: filePath) {
            print("🔍 [DEBUG] GoogleService-Info.plist path: \(filePath)")
            print("🔍 [DEBUG] PROJECT_ID from loaded plist: \(plist["PROJECT_ID"] ?? "not found")")
            print("🔍 [DEBUG] BUNDLE_ID from loaded plist: \(plist["BUNDLE_ID"] ?? "not found")")
        } else {
            print("❌ [DEBUG] GoogleService-Info.plist NOT FOUND in bundle")
        }

        // Firebase初期化（AppDelegate または @main で既に実行されている想定）
        // 念のため、初期化されていない場合に備えてチェック
        if FirebaseApp.app() == nil {
            print("🔵 [FIREBASE] Configuring Firebase...")
            FirebaseApp.configure()
        } else {
            print("🔵 [FIREBASE] Firebase already configured")
        }

        self.auth = Auth.auth()
        self.db = Firestore.firestore()
        print("🔵 [FIREBASE] Current user: \(auth.currentUser?.uid ?? "nil")")

        // Firestoreの設定
        let settings = FirestoreSettings()
        settings.isPersistenceEnabled = true // オフラインキャッシュを有効化
        db.settings = settings

        print("✅ [FIREBASE] FirebaseManager initialized")
    }

    // MARK: - Current User
    var currentUser: User? {
        return auth.currentUser
    }

    var currentUserId: String? {
        return auth.currentUser?.uid
    }

    var isAuthenticated: Bool {
        return auth.currentUser != nil
    }

    // MARK: - Collection References
    var usersCollection: CollectionReference {
        return db.collection("users")
    }

    var postsCollection: CollectionReference {
        return db.collection("posts")
    }

    var followsCollection: CollectionReference {
        return db.collection("follows")
    }

    var followRequestsCollection: CollectionReference {
        return db.collection("followRequests")
    }

    // MARK: - Batch Operations
    func batch() -> WriteBatch {
        return db.batch()
    }

    // MARK: - Transaction
    func runTransaction<T>(_ updateBlock: @escaping (Transaction) throws -> T) async throws -> T {
        return try await db.runTransaction { transaction, errorPointer in
            do {
                return try updateBlock(transaction)
            } catch {
                errorPointer?.pointee = error as NSError
                return nil as T?
            }
        } as! T
    }
}
