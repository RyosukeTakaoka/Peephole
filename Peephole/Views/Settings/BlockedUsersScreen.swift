//
//  BlockedUsersScreen.swift
//  Peephole
//
//  ブロックしたユーザー一覧画面
//  設定画面から遷移し、ブロック中ユーザーの確認・解除を行う
//

import SwiftUI

struct BlockedUsersScreen: View {

    @StateObject private var viewModel = BlockedUsersViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                ProgressView("読み込み中...")
            } else if viewModel.isEmpty {
                EmptyBlockedUsersView(message: viewModel.emptyStateMessage)
            } else {
                List {
                    ForEach(viewModel.blockedUsers) { info in
                        BlockedUserRow(
                            info: info,
                            onUnblock: {
                                Task {
                                    await viewModel.unblockUser(blockedId: info.id)
                                }
                            }
                        )
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.refresh()
                }
            }
        }
        .navigationTitle("ブロックしたユーザー")
        .navigationBarTitleDisplayMode(.inline)
        .alert("エラー", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
            }
        }
        .task {
            if let userId = authViewModel.currentUserId {
                await viewModel.loadBlockedUsers(userId: userId)
            }
        }
    }
}

// MARK: - Blocked User Row

struct BlockedUserRow: View {

    let info: BlockedUsersViewModel.BlockedUserInfo
    let onUnblock: () -> Void

    @State private var showConfirmUnblock = false

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: info.user?.profileImageURL ?? "")) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundColor(.gray)
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                if let user = info.user {
                    Text(user.displayName)
                        .font(.system(size: 16, weight: .semibold))

                    Text("@\(user.username)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                } else {
                    Text("退会したユーザー")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Button("ブロック解除") {
                showConfirmUnblock = true
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.red)
            .confirmationDialog("ブロックを解除しますか？", isPresented: $showConfirmUnblock) {
                Button("ブロック解除", role: .destructive) {
                    onUnblock()
                }
                Button("キャンセル", role: .cancel) {}
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Empty Blocked Users View

struct EmptyBlockedUsersView: View {

    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text(message)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        BlockedUsersScreen()
            .environmentObject(AuthViewModel())
    }
}
