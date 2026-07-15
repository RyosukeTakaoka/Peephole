//
//  AccountDeleteScreen.swift
//  Peephole
//
//  アカウント削除画面
//  影響説明 → パスワード再入力 → 最終確認 → 削除実行
//

import SwiftUI

struct AccountDeleteScreen: View {

    @EnvironmentObject var authViewModel: AuthViewModel

    @State private var password = ""
    @FocusState private var isPasswordFocused: Bool
    @State private var showConfirmDelete = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // 影響説明
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.red)

                    Text("アカウントを削除しますか？")
                        .font(.system(size: 20, weight: .bold))

                    Text("アカウントを削除すると、投稿・フォロー関係・プロフィールなど、すべてのデータが完全に削除され、復元することはできません。")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 24)

                // パスワード入力
                VStack(alignment: .leading, spacing: 8) {
                    Text("パスワード")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)

                    SecureField("現在のパスワードを入力", text: $password)
                        .textContentType(.password)
                        .focused($isPasswordFocused)
                        .padding()
                        .background(Color(.systemBackground))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                        )

                    Text("本人確認のため、現在のパスワードの入力が必要です")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 24)

                // 削除ボタン
                Button(role: .destructive) {
                    isPasswordFocused = false
                    showConfirmDelete = true
                } label: {
                    if authViewModel.isLoading {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    } else {
                        Text("アカウントを削除")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                }
                .background(canDelete ? Color.red : Color.gray)
                .cornerRadius(12)
                .disabled(!canDelete || authViewModel.isLoading)
                .padding(.horizontal, 24)
                .padding(.top, 8)

                Spacer()
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(authViewModel.isLoading)
        .navigationTitle("アカウントを削除")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "本当に削除しますか？この操作は取り消せません",
            isPresented: $showConfirmDelete,
            titleVisibility: .visible
        ) {
            Button("削除する", role: .destructive) {
                Task {
                    await authViewModel.deleteAccount(password: password)
                }
            }
            Button("キャンセル", role: .cancel) {}
        }
        .alert("エラー", isPresented: $authViewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = authViewModel.errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Computed Properties

    private var canDelete: Bool {
        !password.isEmpty
    }
}

#Preview {
    NavigationStack {
        AccountDeleteScreen()
            .environmentObject(AuthViewModel())
    }
}
