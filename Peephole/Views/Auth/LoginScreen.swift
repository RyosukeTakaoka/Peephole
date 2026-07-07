//
//  LoginScreen.swift
//  Peephole
//
//  ログイン画面
//  メール/パスワードでのログイン
//

import SwiftUI

struct LoginScreen: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    enum Field {
        case email, password
    }

    var body: some View {
        ZStack {
            // 背景
            Color(.systemGroupedBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    // ヘッダー
                    VStack(spacing: 8) {
                        Image(systemName: "eye.circle.fill")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)

                        Text("ログイン")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.primary)

                        Text("Peepholeへようこそ")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 20)

                    // フォーム
                    VStack(spacing: 16) {
                        // メールアドレス
                        VStack(alignment: .leading, spacing: 8) {
                            Text("メールアドレス")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            TextField("example@mail.com", text: $email)
                                .textContentType(.emailAddress)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .focused($focusedField, equals: .email)
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }

                        // パスワード
                        VStack(alignment: .leading, spacing: 8) {
                            Text("パスワード")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            SecureField("パスワードを入力", text: $password)
                                .textContentType(.password)
                                .focused($focusedField, equals: .password)
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }

                        // パスワードを忘れた
                        HStack {
                            Spacer()
                            Button {
                                // パスワードリセット機能（将来的な実装）
                            } label: {
                                Text("パスワードを忘れた方はこちら")
                                    .font(.system(size: 14))
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    // ログインボタン
                    Button {
                        focusedField = nil
                        Task {
                            await authViewModel.login(email: email, password: password)
                        }
                    } label: {
                        if authViewModel.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        } else {
                            Text("ログイン")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        }
                    }
                    .background(canLogin ? Color.blue : Color.gray)
                    .cornerRadius(12)
                    .disabled(!canLogin || authViewModel.isLoading)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)

                    Spacer()
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .navigationBarTitleDisplayMode(.inline)
        .alert("エラー", isPresented: $authViewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = authViewModel.errorMessage {
                Text(errorMessage)
            }
        }
        .onChange(of: authViewModel.isAuthenticated) { _, isAuthenticated in
            if isAuthenticated {
                // ログイン成功: 画面を閉じる（MainTabViewに自動遷移）
                dismiss()
            }
        }
    }

    // MARK: - Computed Properties

    private var canLogin: Bool {
        !email.isEmpty && !password.isEmpty
    }
}

#Preview {
    NavigationStack {
        LoginScreen()
            .environmentObject(AuthViewModel())
    }
}
