//
//  UserProfileScreen.swift
//  Peephole
//
//  他ユーザーのプロフィール画面
//  プロフィール表示とフォロー管理
//

import SwiftUI

struct UserProfileScreen: View {

    let targetUserId: String

    @StateObject private var viewModel = UserProfileViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var showCancelConfirmation = false

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                ProgressView("読み込み中...")
            } else if let profile = viewModel.userProfile {
                ScrollView {
                    VStack(spacing: 24) {
                        // プロフィールヘッダー
                        UserProfileHeaderView(
                            profile: profile,
                            profileImageURL: viewModel.profileImageURL,
                            followersCount: viewModel.followersCountText,
                            followingCount: viewModel.followingCountText,
                            postsCount: viewModel.postsCountText,
                            bio: viewModel.bioText
                        )

                        // フォローボタン
                        Button {
                            if viewModel.followStatus == .requestPending {
                                // 誤タップ防止のため確認ダイアログを挟む
                                showCancelConfirmation = true
                            } else {
                                Task {
                                    await viewModel.handleFollowButtonTapped()
                                }
                            }
                        } label: {
                            if viewModel.isFollowActionInProgress {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            } else {
                                Text(viewModel.followStatus.buttonTitle)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                            }
                        }
                        .background(viewModel.followStatus.buttonColor)
                        .cornerRadius(8)
                        .disabled(viewModel.isFollowActionInProgress)
                        .padding(.horizontal, 16)
                        .confirmationDialog("リクエストを取り消しますか？", isPresented: $showCancelConfirmation) {
                            Button("取り消す", role: .destructive) {
                                Task {
                                    await viewModel.handleFollowButtonTapped()
                                }
                            }
                            Button("キャンセル", role: .cancel) {}
                        }

                        // 投稿一覧
                        VStack(alignment: .leading, spacing: 12) {
                            Text("投稿")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 16)

                            if !viewModel.canViewPosts {
                                EmptyPostsView(message: viewModel.emptyPostsMessage)
                            } else if viewModel.hasNoPosts {
                                EmptyPostsView(message: viewModel.emptyPostsMessage)
                            } else {
                                PostsGridView(posts: viewModel.posts)
                            }
                        }
                    }
                    .padding(.vertical, 20)
                }
                .refreshable {
                    await viewModel.refreshProfile()
                }
            }
        }
        .navigationTitle("プロフィール")
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
            if let currentUserId = authViewModel.currentUserId {
                await viewModel.loadUserProfile(
                    targetUserId: targetUserId,
                    currentUserId: currentUserId
                )
            }
        }
    }
}

// MARK: - User Profile Header View

struct UserProfileHeaderView: View {

    let profile: FirestoreUser
    let profileImageURL: String?
    let followersCount: String
    let followingCount: String
    let postsCount: String
    let bio: String

    var body: some View {
        VStack(spacing: 16) {
            // プロフィール画像
            AsyncImage(url: URL(string: profileImageURL ?? "")) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundColor(.gray)
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 2)
            )

            // ユーザー名
            VStack(spacing: 4) {
                Text(profile.displayName)
                    .font(.system(size: 22, weight: .bold))

                Text("@\(profile.username)")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
            }

            // 自己紹介
            Text(bio)
                .font(.system(size: 15))
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // 統計情報
            HStack(spacing: 32) {
                StatItemView(count: postsCount, label: "投稿")
                StatItemView(count: followersCount, label: "フォロワー")
                StatItemView(count: followingCount, label: "フォロー中")
            }
            .padding(.top, 8)
        }
    }
}

#Preview {
    NavigationStack {
        UserProfileScreen(targetUserId: "sample_user_id")
            .environmentObject(AuthViewModel())
    }
}
