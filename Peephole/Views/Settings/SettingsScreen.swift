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

    var body: some View {
        List {
            Section("アカウント") {
            }

            Section("情報") {
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
    }
}

#Preview {
    NavigationStack {
        SettingsScreen()
            .environmentObject(AuthViewModel())
    }
}
