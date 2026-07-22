//
//  HomeScreen.swift
//  Peephole
//
//  ホーム画面（タイムライン）
//  フォロー中のユーザーの投稿を時系列で表示
//

import SwiftUI
import GoogleMobileAds

struct HomeScreen: View {

    @StateObject private var viewModel = HomeViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel

    @State private var reportingPost: FirestorePost?
    @State private var showUserSearch = false

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                // 初回ローディング
                ProgressView("読み込み中...")
            } else if viewModel.isEmpty {
                // 空の状態
                EmptyStateView(message: viewModel.emptyStateMessage)
            } else {
                // タイムライン表示
                ScrollView {
                    LazyVStack(spacing: 16) {
                        // 投稿と広告を混ぜた表示用アイテム列を回す
                        ForEach(viewModel.feedItems) { item in
                            switch item {
                            case .post(let post):
                                PostCardView(
                                    post: post,
                                    currentUserId: authViewModel.currentUserId,
                                    onBlock: {
                                        Task {
                                            await viewModel.blockUser(userId: post.userId)
                                        }
                                    },
                                    onDelete: {
                                        Task {
                                            await viewModel.deletePost(postId: post.postId)
                                        }
                                    },
                                    onReport: {
                                        reportingPost = post
                                    }
                                )
                                .onAppear {
                                    // 無限スクロール（判定は投稿に対してのみ行う）
                                    viewModel.checkIfShouldLoadMore(for: post)
                                }

                            case .ad(_, let nativeAd):
                                // ネイティブ広告セル
                                NativeAdCardView(nativeAd: nativeAd)
                            }
                        }

                        // さらに読み込み中
                        if viewModel.isLoadingMore {
                            ProgressView()
                                .padding()
                        }
                    }
                    .padding(.vertical, 8)
                }
                .refreshable {
                    await viewModel.refreshTimeline()
                }
            }
        }
        .navigationTitle("ホーム")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showUserSearch = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
            }
        }
        .navigationDestination(isPresented: $showUserSearch) {
            UserSearchScreen()
                .environmentObject(authViewModel)
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
                await viewModel.loadTimeline(userId: userId)
            }
        }
        .sheet(item: $reportingPost) { post in
            ReportScreen(
                reporterId: authViewModel.currentUserId ?? "",
                targetType: .post,
                targetPostId: post.postId,
                targetUserId: post.userId,
                onReported: {
                    viewModel.removeReportedPost(postId: post.postId)
                }
            )
        }
    }
}

// MARK: - Post Card View

struct PostCardView: View {

    let post: FirestorePost
    let currentUserId: String?
    let onBlock: () -> Void
    let onDelete: () -> Void
    let onReport: () -> Void

    @State private var showBlockConfirm = false
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // ユーザー情報
            HStack(spacing: 12) {
                // プロフィール画像
                AsyncImage(url: URL(string: post.userProfileImageURL ?? "")) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundColor(.gray)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(post.userDisplayName)
                        .font(.system(size: 16, weight: .semibold))

                    Text("@\(post.userName)")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }

                Spacer()

                // 投稿日時
                Text(timeAgo(from: post.createdAt))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                // メニュー（ブロック・削除）
                Menu {
                    if post.userId == currentUserId {
                        Button("投稿を削除", role: .destructive) {
                            showDeleteConfirm = true
                        }
                    } else {
                        Button("このユーザーをブロック", role: .destructive) {
                            showBlockConfirm = true
                        }
                        Button("この投稿を通報") {
                            onReport()
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundColor(.secondary)
                        .padding(.leading, 4)
                }
            }

            // 投稿画像
            AsyncImage(url: URL(string: post.thumbnailURL)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(
                        ProgressView()
                    )
            }
            .frame(maxWidth: .infinity)
            .frame(height: 300)
            .cornerRadius(12)
            .clipped()

            // 投稿テキスト
            Text(post.text)
                .font(.system(size: 16))
                .foregroundColor(.primary)

            // 曲情報
            if let song = post.song {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .foregroundColor(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(song.title)
                            .font(.system(size: 14, weight: .medium))

                        Text(song.artist)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }

                    Spacer()
                }
                .padding(12)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
        .padding(.horizontal, 16)
        .confirmationDialog("このユーザーをブロックしますか？", isPresented: $showBlockConfirm) {
            Button("ブロックする", role: .destructive) {
                onBlock()
            }
            Button("キャンセル", role: .cancel) {}
        }
        .confirmationDialog("この投稿を削除しますか？", isPresented: $showDeleteConfirm) {
            Button("削除する", role: .destructive) {
                onDelete()
            }
            Button("キャンセル", role: .cancel) {}
        }
    }

    // MARK: - Time Ago Helper

    private func timeAgo(from date: Date) -> String {
        let now = Date()
        let interval = now.timeIntervalSince(date)

        if interval < 60 {
            return "たった今"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)分前"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)時間前"
        } else {
            let days = Int(interval / 86400)
            return "\(days)日前"
        }
    }
}

// MARK: - Empty State View

struct EmptyStateView: View {

    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "tray")
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
        HomeScreen()
            .environmentObject(AuthViewModel())
    }
}
