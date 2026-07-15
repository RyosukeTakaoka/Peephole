//
//  SignUpScreen.swift
//  Peephole
//
//  新規登録画面
//  ユーザー名、表示名、メール、パスワードで新規登録
//

import SwiftUI

struct SignUpScreen: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var displayName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var agreedToTerms = false
    @State private var showTerms = false
    @State private var showPrivacyPolicy = false
    @FocusState private var focusedField: Field?

    enum Field {
        case username, displayName, email, password, confirmPassword
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
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 60))
                            .foregroundColor(.blue)

                        Text("新規登録")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(.primary)

                        Text("アカウントを作成しましょう")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 40)
                    .padding(.bottom, 20)

                    // フォーム
                    VStack(spacing: 16) {
                        // ユーザー名
                        VStack(alignment: .leading, spacing: 8) {
                            Text("ユーザー名")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            HStack {
                                Text("@")
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 12)

                                TextField("username", text: $username)
                                    .textContentType(.username)
                                    .autocapitalization(.none)
                                    .focused($focusedField, equals: .username)
                                    .onChange(of: username) { _, newValue in
                                        // 英数字とアンダースコアのみ許可
                                        username = newValue.filter { $0.isLetter || $0.isNumber || $0 == "_" }
                                    }
                            }
                            .padding(.vertical, 14)
                            .background(Color(.systemBackground))
                            .cornerRadius(10)
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                            Text("3文字以上、英数字とアンダースコアのみ")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        // 表示名
                        VStack(alignment: .leading, spacing: 8) {
                            Text("表示名")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            TextField("山田太郎", text: $displayName)
                                .textContentType(.name)
                                .focused($focusedField, equals: .displayName)
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }

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

                            SecureField("6文字以上", text: $password)
                                .textContentType(.newPassword)
                                .focused($focusedField, equals: .password)
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }

                        // パスワード確認
                        VStack(alignment: .leading, spacing: 8) {
                            Text("パスワード（確認）")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            SecureField("パスワードを再入力", text: $confirmPassword)
                                .textContentType(.newPassword)
                                .focused($focusedField, equals: .confirmPassword)
                                .padding()
                                .background(Color(.systemBackground))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(passwordsMatch ? Color.gray.opacity(0.3) : Color.red, lineWidth: 1)
                                )

                            if !confirmPassword.isEmpty && !passwordsMatch {
                                Text("パスワードが一致しません")
                                    .font(.system(size: 12))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(.horizontal, 24)

                    // 利用規約への同意
                    HStack(alignment: .center, spacing: 4) {
                        Button {
                            agreedToTerms.toggle()
                        } label: {
                            Image(systemName: agreedToTerms ? "checkmark.square.fill" : "square")
                                .foregroundColor(agreedToTerms ? .blue : .secondary)
                        }

                        Button {
                            showTerms = true
                        } label: {
                            Text("利用規約")
                                .font(.system(size: 14))
                                .foregroundColor(.blue)
                        }

                        Text("と")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)

                        Button {
                            showPrivacyPolicy = true
                        } label: {
                            Text("プライバシーポリシー")
                                .font(.system(size: 14))
                                .foregroundColor(.blue)
                        }

                        Text("に同意します")
                            .font(.system(size: 14))
                            .foregroundColor(.primary)

                        Spacer()
                    }
                    .padding(.horizontal, 24)

                    // 登録ボタン
                    Button {
                        focusedField = nil
                        Task {
                            await authViewModel.signUp(
                                email: email,
                                password: password,
                                username: username,
                                displayName: displayName
                            )
                        }
                    } label: {
                        if authViewModel.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        } else {
                            Text("登録")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                        }
                    }
                    .background(canSignUp ? Color.blue : Color.gray)
                    .cornerRadius(12)
                    .disabled(!canSignUp || authViewModel.isLoading)
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
                // 登録成功: 画面を閉じる（MainTabViewに自動遷移）
                dismiss()
            }
        }
        .sheet(isPresented: $showTerms) {
            TermsScreen(documentType: .terms)
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            TermsScreen(documentType: .privacyPolicy)
        }
    }

    // MARK: - Computed Properties

    private var passwordsMatch: Bool {
        password == confirmPassword
    }

    private var canSignUp: Bool {
        !username.isEmpty &&
        username.count >= 3 &&
        !displayName.isEmpty &&
        !email.isEmpty &&
        !password.isEmpty &&
        password.count >= 6 &&
        passwordsMatch &&
        agreedToTerms
    }
}

#Preview {
    NavigationStack {
        SignUpScreen()
            .environmentObject(AuthViewModel())
    }
}
