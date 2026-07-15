//
//  ProfileScreen.swift
//  Peephole
//
//  自分のプロフィール画面
//  プロフィール情報と投稿一覧を表示
//

import SwiftUI

struct ProfileScreen: View {

    @StateObject private var viewModel = ProfileViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel

    @State private var showSettings = false
    @State private var showEditProfile = false

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                ProgressView("読み込み中...")
            } else if let profile = viewModel.userProfile {
                ScrollView {
                    VStack(spacing: 24) {
                        // プロフィールヘッダー
                        ProfileHeaderView(
                            profile: profile,
                            profileImageURL: viewModel.profileImageURL,
                            followersCount: viewModel.followersCountText,
                            followingCount: viewModel.followingCountText,
                            postsCount: viewModel.postsCountText,
                            bio: viewModel.bioText
                        )

                        // プロフィール編集ボタン
                        Button {
                            showEditProfile = true
                        } label: {
                            Text("プロフィールを編集")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                        .padding(.horizontal, 16)

                        // 投稿一覧
                        VStack(alignment: .leading, spacing: 12) {
                            Text("投稿")
                                .font(.system(size: 18, weight: .bold))
                                .padding(.horizontal, 16)

                            if viewModel.hasNoPosts {
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
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showEditProfile, onDismiss: {
            Task {
                await authViewModel.refreshCurrentUser()
            }
        }) {
            EditProfileScreen(viewModel: viewModel)
        }
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
                await viewModel.loadProfile(userId: userId)
            }
        }
    }
}

// MARK: - Profile Header View

struct ProfileHeaderView: View {

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

// MARK: - Stat Item View

struct StatItemView: View {

    let count: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(count)
                .font(.system(size: 20, weight: .bold))

            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Posts Grid View

struct PostsGridView: View {

    let posts: [FirestorePost]

    let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(posts) { post in
                AsyncImage(url: URL(string: post.thumbnailURL)) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                }
                .frame(height: 120)
                .clipped()
            }
        }
    }
}

// MARK: - Empty Posts View

struct EmptyPostsView: View {

    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 50))
                .foregroundColor(.gray)

            Text(message)
                .font(.system(size: 15))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

// MARK: - Settings View (簡易版)

struct SettingsView: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
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
}

#Preview {
    NavigationStack {
        ProfileScreen()
            .environmentObject(AuthViewModel())
    }
}
