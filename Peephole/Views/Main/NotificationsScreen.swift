//
//  NotificationsScreen.swift
//  Peephole
//
//  通知画面
//  フォローリクエストの承認・拒否
//

import SwiftUI

struct NotificationsScreen: View {

    @StateObject private var viewModel = NotificationsViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                // 初回ローディング
                ProgressView("読み込み中...")
            } else if viewModel.isEmpty {
                // 空の状態
                EmptyNotificationsView(message: viewModel.emptyStateMessage)
            } else {
                // フォローリクエスト一覧
                List {
                    ForEach(viewModel.followRequests) { requestWithUser in
                        FollowRequestRow(
                            requestWithUser: requestWithUser,
                            onApprove: {
                                Task {
                                    await viewModel.approveRequest(requestId: requestWithUser.id)
                                }
                            },
                            onReject: {
                                Task {
                                    await viewModel.rejectRequest(requestId: requestWithUser.id)
                                }
                            }
                        )
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await viewModel.refreshRequests()
                }
            }
        }
        .navigationTitle("通知")
        .navigationBarTitleDisplayMode(.inline)
        .alert("エラー", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
            }
        }
        .task {
            // 初回読み込み
            if let userId = authViewModel.currentUserId {
                await viewModel.loadFollowRequests(userId: userId)
            }
        }
    }
}

// MARK: - Follow Request Row

struct FollowRequestRow: View {

    let requestWithUser: NotificationsViewModel.FollowRequestWithUser
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var showConfirmApprove = false
    @State private var showConfirmReject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                // プロフィール画像
                AsyncImage(url: URL(string: requestWithUser.requester.profileImageURL ?? "")) { image in
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
                    Text(requestWithUser.requester.displayName)
                        .font(.system(size: 16, weight: .semibold))

                    Text("@\(requestWithUser.requester.username)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)

                    Text("あなたをフォローリクエストしました")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }

                Spacer()
            }

            // 承認/拒否ボタン
            HStack(spacing: 12) {
                // 承認ボタン
                Button {
                    showConfirmApprove = true
                } label: {
                    Text("承認")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue)
                        .cornerRadius(8)
                }
                .confirmationDialog("フォローリクエストを承認しますか？", isPresented: $showConfirmApprove) {
                    Button("承認") {
                        onApprove()
                    }
                    Button("キャンセル", role: .cancel) {}
                }

                // 拒否ボタン
                Button {
                    showConfirmReject = true
                } label: {
                    Text("拒否")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.red.opacity(0.1))
                        .cornerRadius(8)
                }
                .confirmationDialog("フォローリクエストを拒否しますか？", isPresented: $showConfirmReject) {
                    Button("拒否", role: .destructive) {
                        onReject()
                    }
                    Button("キャンセル", role: .cancel) {}
                }
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Empty Notifications View

struct EmptyNotificationsView: View {

    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "bell.slash")
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
        NotificationsScreen()
            .environmentObject(AuthViewModel())
    }
}
