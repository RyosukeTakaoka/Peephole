//
//  AuthViewModel.swift
//  Peephole
//
//  認証状態の管理を行うViewModel
//  ログイン、サインアップ、ログアウト処理を担当
//

import Foundation
import SwiftUI
import Combine
import FirebaseAuth

@MainActor
class AuthViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 初期化中フラグ（認証状態確認中）
    @Published var isInitializing: Bool = true

    /// ログイン状態
    @Published var isAuthenticated: Bool = false

    /// 現在のユーザーID
    @Published var currentUserId: String?

    /// 現在のユーザー情報（Firestoreから取得）
    @Published var currentUser: PeepholeUser?

    /// 規約への（再）同意が必要かどうか
    @Published var needsTermsAgreement: Bool = false

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    // MARK: - Services

    private let authService = AuthenticationService.shared
    private let userService = UserService.shared

    // MARK: - Private Properties

    private var authStateListener: AuthStateDidChangeListenerHandle?

    // MARK: - Initialization

    init() {
        print("🔵 [VIEWMODEL] AuthViewModel init() - Setting up auth state listener")
        // 認証状態の監視を開始
        setupAuthStateListener()
    }

    deinit {
        // リスナーをクリーンアップ
        if let handle = authStateListener {
            authService.removeStateDidChangeListener(handle)
        }
    }

    // MARK: - Auth State Listener

    /// 認証状態の変化を監視
    private func setupAuthStateListener() {
        print("🔵 [VIEWMODEL] setupAuthStateListener() called")
        authStateListener = authService.addStateDidChangeListener { [weak self] user in
            Task { @MainActor [weak self] in
                guard let self = self else {
                    print("⚠️ [VIEWMODEL] Auth state changed but self is nil")
                    return
                }

                print("🔵 [VIEWMODEL] Auth state changed - user: \(user?.uid ?? "nil")")

                if let user = user {
                    // ログイン中
                    print("✅ [VIEWMODEL] User is authenticated: \(user.uid)")
                    self.isAuthenticated = true
                    self.currentUserId = user.uid

                    // Firestoreからユーザー情報を取得
                    print("🔵 [VIEWMODEL] Fetching user profile from Firestore...")
                    await self.fetchCurrentUser(userId: user.uid)
                } else {
                    // ログアウト状態
                    print("✅ [VIEWMODEL] User is not authenticated (logged out)")
                    self.isAuthenticated = false
                    self.currentUserId = nil
                    self.currentUser = nil
                }

                // 初期化完了
                print("✅ [VIEWMODEL] Auth initialization completed (isInitializing = false)")
                self.isInitializing = false
            }
        }
    }

    // MARK: - Sign Up

    /// 新規ユーザー登録
    /// - Parameters:
    ///   - email: メールアドレス
    ///   - password: パスワード
    ///   - username: ユーザー名（@username）
    ///   - displayName: 表示名
    func signUp(email: String, password: String, username: String, displayName: String) async {
        print("🔵 [VIEWMODEL] signUp started")
        isLoading = true
        errorMessage = nil

        do {
            // バリデーション
            print("🔵 [VIEWMODEL] Validating input...")
            try validateSignUpInput(email: email, password: password, username: username, displayName: displayName)
            print("✅ [VIEWMODEL] Input validation passed")

            // Firebase Authでユーザー作成
            print("🔵 [VIEWMODEL] Creating Firebase Auth user...")
            let userId = try await authService.signUp(email: email, password: password)
            print("✅ [VIEWMODEL] Firebase Auth user created: \(userId)")

            // Firestoreにユーザープロフィール作成
            print("🔵 [VIEWMODEL] Creating Firestore user profile...")
            try await userService.createUserProfile(
                userId: userId,
                username: username,
                displayName: displayName,
                email: email
            )

            print("✅ [VIEWMODEL] Sign up completed successfully: \(userId)")

        } catch let error as AuthError {
            print("❌ [VIEWMODEL] Sign up failed with AuthError")
            print("   - Error description: \(error.errorDescription ?? "nil")")
            self.errorMessage = error.errorDescription
            self.showError = true
        } catch let error as UserServiceError {
            print("❌ [VIEWMODEL] Sign up failed with UserServiceError")
            print("   - Error description: \(error.errorDescription ?? "nil")")
            self.errorMessage = error.errorDescription
            self.showError = true
        } catch let error as NSError {
            print("❌ [VIEWMODEL] Sign up failed with NSError")
            print("   - Error code: \(error.code)")
            print("   - Error domain: \(error.domain)")
            print("   - Error description: \(error.localizedDescription)")
            print("   - Error userInfo: \(error.userInfo)")
            self.errorMessage = "エラーが発生しました: \(error.localizedDescription)"
            self.showError = true
        } catch {
            print("❌ [VIEWMODEL] Sign up failed with unknown error")
            print("   - Error: \(error)")
            print("   - Error description: \(error.localizedDescription)")
            self.errorMessage = error.localizedDescription
            self.showError = true
        }

        isLoading = false
        print("🔵 [VIEWMODEL] signUp completed (isLoading = false)")
    }

    // MARK: - Login

    /// ログイン
    /// - Parameters:
    ///   - email: メールアドレス
    ///   - password: パスワード
    func login(email: String, password: String) async {
        isLoading = true
        errorMessage = nil

        do {
            // バリデーション
            guard !email.isEmpty, !password.isEmpty else {
                throw AuthError.invalidEmail
            }

            // ログイン処理
            let userId = try await authService.login(email: email, password: password)

            print("✅ Login completed: \(userId)")

        } catch let error as AuthError {
            self.errorMessage = error.errorDescription
            self.showError = true
        } catch {
            self.errorMessage = error.localizedDescription
            self.showError = true
        }

        isLoading = false
    }

    // MARK: - Logout

    /// ログアウト
    func logout() {
        do {
            try authService.logout()

            // 他人のデータがウィジェットに残らないようクリアする
            SharedDataManager.clearWidgetData()

            print("✅ Logout completed")
        } catch {
            self.errorMessage = "ログアウトに失敗しました"
            self.showError = true
        }
    }

    // MARK: - Password Reset

    /// パスワードリセットメールを送信
    /// - Parameter email: メールアドレス
    func sendPasswordReset(email: String) async {
        isLoading = true
        errorMessage = nil

        do {
            guard !email.isEmpty else {
                throw AuthError.invalidEmail
            }

            try await authService.sendPasswordReset(email: email)

            // 成功メッセージ（エラーメッセージを成功メッセージとして流用）
            self.errorMessage = "パスワードリセットメールを送信しました"
            self.showError = true

        } catch let error as AuthError {
            self.errorMessage = error.errorDescription
            self.showError = true
        } catch {
            self.errorMessage = error.localizedDescription
            self.showError = true
        }

        isLoading = false
    }

    // MARK: - Fetch Current User

    /// 現在のユーザー情報をFirestoreから取得
    private func fetchCurrentUser(userId: String) async {
        print("🔵 [VIEWMODEL] fetchCurrentUser() started for userId: \(userId)")
        do {
            let firestoreUser = try await userService.getUserProfile(userId: userId)
            self.currentUser = firestoreUser.toPeepholeUser()
            self.needsTermsAgreement = firestoreUser.agreedTermsVersion != LegalTexts.currentTermsVersion
            print("✅ [VIEWMODEL] Current user fetched successfully: @\(firestoreUser.username)")
        } catch let error as UserServiceError {
            print("❌ [VIEWMODEL] Failed to fetch current user - UserServiceError")
            print("   - Error description: \(error.errorDescription ?? "nil")")
            print("   ⚠️ This error is NOT shown to the user (by design)")
        } catch let error as NSError {
            print("❌ [VIEWMODEL] Failed to fetch current user - NSError")
            print("   - Error code: \(error.code)")
            print("   - Error domain: \(error.domain)")
            print("   - Error description: \(error.localizedDescription)")
            print("   - Error userInfo: \(error.userInfo)")
            print("   ⚠️ This error is NOT shown to the user (by design)")
        } catch {
            print("❌ [VIEWMODEL] Failed to fetch current user - Unknown error")
            print("   - Error: \(error)")
            print("   - Error description: \(error.localizedDescription)")
            print("   ⚠️ This error is NOT shown to the user (by design)")
        }
    }

    /// ユーザー情報を手動で更新（プロフィール編集後に呼び出す）
    func refreshCurrentUser() async {
        guard let userId = currentUserId else { return }
        await fetchCurrentUser(userId: userId)
    }

    // MARK: - Agree to Current Terms

    /// 現在の規約バージョンに同意する（再同意フロー用）
    func agreeToCurrentTerms() async {
        guard let userId = currentUserId else { return }

        do {
            try await userService.updateTermsAgreement(userId: userId, version: LegalTexts.currentTermsVersion)
            self.needsTermsAgreement = false
            print("✅ [VIEWMODEL] Agreed to current terms: \(LegalTexts.currentTermsVersion)")
        } catch {
            print("❌ [VIEWMODEL] Failed to agree to current terms: \(error)")
            self.errorMessage = "規約への同意の保存に失敗しました"
            self.showError = true
        }
    }

    // MARK: - Validation

    /// サインアップ入力のバリデーション
    private func validateSignUpInput(email: String, password: String, username: String, displayName: String) throws {
        // メールアドレスチェック
        guard !email.isEmpty, email.contains("@") else {
            throw AuthError.invalidEmail
        }

        // パスワードチェック
        guard password.count >= 6 else {
            throw AuthError.weakPassword
        }

        // ユーザー名チェック
        guard !username.isEmpty, username.count >= 3 else {
            throw AuthError.unknown("ユーザー名は3文字以上で入力してください")
        }

        // 表示名チェック
        guard !displayName.isEmpty else {
            throw AuthError.unknown("表示名を入力してください")
        }
    }

    // MARK: - Delete Account

    /// アカウントを削除する
    /// 手順: ①パスワード再認証 → ②Firestoreデータ削除 → ③Firebase Authアカウント削除 → ④ウィジェットデータ削除
    /// - Parameter password: 再認証用のパスワード
    func deleteAccount(password: String) async {
        isLoading = true
        errorMessage = nil

        do {
            guard let userId = currentUserId else {
                throw AuthError.userNotFound
            }

            // ①パスワード再認証（Firebase Authはdelete()に直近ログインを要求するため）
            try await authService.reauthenticate(password: password)

            // ②Firestore上の当該ユーザー由来データをカスケード削除
            try await userService.deleteUserData(userId: userId)

            // ③Firebase Authのアカウントを削除
            // 成功するとauth state listenerが発火し、RootViewが自動的にWelcomeScreenへ戻る
            try await authService.deleteAccount()

            // ④ウィジェットデータを削除
            SharedDataManager.clearWidgetData()

            print("✅ Account deleted")

        } catch let error as AuthError {
            self.errorMessage = error.errorDescription
            self.showError = true
        } catch let error as UserServiceError {
            self.errorMessage = error.errorDescription
            self.showError = true
        } catch {
            self.errorMessage = error.localizedDescription
            self.showError = true
        }

        isLoading = false
    }
}
