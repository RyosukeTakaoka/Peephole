//
//  AuthenticationService.swift
//  Peephole
//
//  Firebase Authentication のラッパークラス
//  ログイン、サインアップ、ログアウトなどの認証処理を担当
//

import Foundation
import FirebaseAuth

enum AuthError: LocalizedError {
    case invalidEmail
    case weakPassword
    case emailAlreadyInUse
    case userNotFound
    case wrongPassword
    case networkError
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmail:
            return "メールアドレスの形式が正しくありません"
        case .weakPassword:
            return "パスワードは6文字以上である必要があります"
        case .emailAlreadyInUse:
            return "このメールアドレスは既に使用されています"
        case .userNotFound:
            return "ユーザーが見つかりません"
        case .wrongPassword:
            return "パスワードが間違っています"
        case .networkError:
            return "ネットワークエラーが発生しました"
        case .unknown(let message):
            return "エラーが発生しました: \(message)"
        }
    }
}

class AuthenticationService {

    // MARK: - Singleton
    static let shared = AuthenticationService()

    private let auth = FirebaseManager.shared.auth

    private init() {}

    // MARK: - Sign Up
    /// 新規ユーザー登録
    /// - Parameters:
    ///   - email: メールアドレス
    ///   - password: パスワード
    /// - Returns: 作成されたユーザーのUID
    func signUp(email: String, password: String) async throws -> String {
        print("🔵 [AUTH] signUp started - email: \(email)")
        do {
            let result = try await auth.createUser(withEmail: email, password: password)
            print("✅ [AUTH] User created successfully: \(result.user.uid)")
            return result.user.uid
        } catch let error as NSError {
            print("❌ [AUTH] signUp failed")
            print("   - Error code: \(error.code)")
            print("   - Error domain: \(error.domain)")
            print("   - Error description: \(error.localizedDescription)")
            print("   - Error userInfo: \(error.userInfo)")
            throw mapAuthError(error)
        }
    }

    // MARK: - Login
    /// ログイン
    /// - Parameters:
    ///   - email: メールアドレス
    ///   - password: パスワード
    /// - Returns: ログインしたユーザーのUID
    func login(email: String, password: String) async throws -> String {
        do {
            let result = try await auth.signIn(withEmail: email, password: password)
            print("✅ User logged in: \(result.user.uid)")
            return result.user.uid
        } catch let error as NSError {
            throw mapAuthError(error)
        }
    }

    // MARK: - Logout
    /// ログアウト
    func logout() throws {
        do {
            try auth.signOut()
            print("✅ User logged out")
        } catch {
            throw AuthError.unknown("ログアウトに失敗しました")
        }
    }

    // MARK: - Password Reset
    /// パスワードリセットメールを送信
    /// - Parameter email: メールアドレス
    func sendPasswordReset(email: String) async throws {
        do {
            try await auth.sendPasswordReset(withEmail: email)
            print("✅ Password reset email sent to: \(email)")
        } catch let error as NSError {
            throw mapAuthError(error)
        }
    }

    // MARK: - Current User
    /// 現在ログイン中のユーザーのUID
    var currentUserId: String? {
        return auth.currentUser?.uid
    }

    /// 現在ログイン中のユーザーのメールアドレス
    var currentUserEmail: String? {
        return auth.currentUser?.email
    }

    /// ログイン状態
    var isAuthenticated: Bool {
        return auth.currentUser != nil
    }

    // MARK: - Delete Account
    /// アカウントを削除（将来的な拡張用）
    func deleteAccount() async throws {
        guard let user = auth.currentUser else {
            throw AuthError.userNotFound
        }

        do {
            try await user.delete()
            print("✅ User account deleted")
        } catch let error as NSError {
            throw mapAuthError(error)
        }
    }

    // MARK: - Error Mapping
    /// FirebaseのエラーコードをAuthErrorにマッピング
    private func mapAuthError(_ error: NSError) -> AuthError {
        guard let errorCode = AuthErrorCode(rawValue: error.code) else {
            return .unknown(error.localizedDescription)
        }

        switch errorCode {
        case .invalidEmail:
            return .invalidEmail
        case .weakPassword:
            return .weakPassword
        case .emailAlreadyInUse:
            return .emailAlreadyInUse
        case .userNotFound:
            return .userNotFound
        case .wrongPassword:
            return .wrongPassword
        case .networkError:
            return .networkError
        default:
            return .unknown(error.localizedDescription)
        }
    }

    // MARK: - Auth State Listener
    /// 認証状態の変化を監視（ViewModelで使用）
    func addStateDidChangeListener(completion: @escaping (User?) -> Void) -> AuthStateDidChangeListenerHandle {
        return auth.addStateDidChangeListener { _, user in
            completion(user)
        }
    }

    /// リスナーを削除
    func removeStateDidChangeListener(_ handle: AuthStateDidChangeListenerHandle) {
        auth.removeStateDidChangeListener(handle)
    }
}
