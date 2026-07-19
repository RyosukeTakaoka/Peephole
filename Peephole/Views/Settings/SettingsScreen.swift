//
//  SettingsScreen.swift
//  Peephole
//
//  設定画面
//  アカウント関連・規約情報・セッション管理をまとめる
//

import SwiftUI

struct SettingsScreen: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showTerms = false
    @State private var showPrivacyPolicy = false

    var body: some View {
        List {
            Section("アカウント") {
                NavigationLink("ブロックしたユーザー") {
                    BlockedUsersScreen()
                }

                NavigationLink {
                    AccountDeleteScreen()
                } label: {
                    Text("アカウントを削除")
                        .foregroundColor(.red)
                }
            }

            Section("情報") {
                Button {
                    showTerms = true
                } label: {
                    Text("利用規約")
                        .foregroundColor(.primary)
                }

                Button {
                    showPrivacyPolicy = true
                } label: {
                    Text("プライバシーポリシー")
                        .foregroundColor(.primary)
                }
            }

            Section("セッション") {
                Button(role: .destructive) {
                    authViewModel.logout()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text("ログアウト")
                    }
                }
            }
        }
        .navigationTitle("設定")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("閉じる") {
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showTerms) {
            TermsScreen(documentType: .terms)
        }
        .sheet(isPresented: $showPrivacyPolicy) {
            TermsScreen(documentType: .privacyPolicy)
        }
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
            .environmentObject(AuthViewModel())
    }
}
