//
//  UserProfileViewModel.swift
//  Peephole
//
//  他ユーザーのプロフィール画面を管理するViewModel
//  プロフィール表示、フォロー状態管理、フォロー/解除を担当
//

import Foundation
import SwiftUI
import Combine

@MainActor
class UserProfileViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 対象ユーザーのプロフィール情報
    @Published var userProfile: FirestoreUser?

    /// 対象ユーザーの投稿一覧
    @Published var posts: [FirestorePost] = []

    /// フォロー状態
    @Published var followStatus: FollowStatus = .notFollowing

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// 投稿読み込み中
    @Published var isLoadingPosts: Bool = false

    /// フォロー操作中
    @Published var isFollowActionInProgress: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    // MARK: - Follow Status Enum

    enum FollowStatus {
        case notFollowing       // 未フォロー
        case requestPending     // リクエスト送信済み
        case following          // フォロー中

        var buttonTitle: String {
            switch self {
            case .notFollowing:
                return "フォローする"
            case .requestPending:
                return "リクエスト中"
            case .following:
                return "フォロー中"
            }
        }

        var buttonColor: Color {
            switch self {
            case .notFollowing:
                return .blue
            case .requestPending:
                return .gray
            case .following:
                return .green
            }
        }
    }

    // MARK: - Services

    private let userService = UserService.shared
    private let postService = PostService.shared
    private let followService = FollowService.shared

    // MARK: - Private Properties

    private var targetUserId: String?
    private var currentUserId: String?

    // MARK: - Load User Profile

    /// ユーザープロフィールを読み込む
    /// - Parameters:
    ///   - targetUserId: 対象ユーザーのID
    ///   - currentUserId: 現在のユーザーID
    func loadUserProfile(targetUserId: String, currentUserId: String) async {
        self.targetUserId = targetUserId
        self.currentUserId = currentUserId
        isLoading = true
        errorMessage = nil

        do {
            // プロフィール情報を取得
            let profile = try await userService.getUserProfile(userId: targetUserId)
            self.userProfile = profile

            print("✅ User profile loaded: @\(profile.username)")

            // フォロー状態をチェック
            await checkFollowStatus()

            // フォロー中の場合のみ投稿を読み込む
            if followStatus == .following {
                await loadPosts()
            }

        } catch {
            self.errorMessage = "プロフィールの読み込みに失敗しました"
            self.showError = true
            print("❌ Failed to load user profile: \(error)")
        }

        isLoading = false
    }

    // MARK: - Check Follow Status

    /// フォロー状態をチェック
    private func checkFollowStatus() async {
        guard let targetUserId = targetUserId,
              let currentUserId = currentUserId else { return }

        do {
            // フォロー中かチェック
            let isFollowing = try await followService.checkIfFollowing(
                followerId: currentUserId,
                followingId: targetUserId
            )

            if isFollowing {
                self.followStatus = .following
                return
            }

            // リクエスト送信済みかチェック
            let pendingRequests = try await followService.getPendingFollowRequests(targetId: targetUserId)
            let hasRequestFromCurrentUser = pendingRequests.contains { $0.requesterId == currentUserId }

            if hasRequestFromCurrentUser {
                self.followStatus = .requestPending
            } else {
                self.followStatus = .notFollowing
            }

            print("✅ Follow status checked: \(followStatus)")

        } catch {
            print("⚠️ Failed to check follow status: \(error)")
            self.followStatus = .notFollowing
        }
    }

    // MARK: - Load Posts

    /// 投稿一覧を読み込む
    private func loadPosts() async {
        guard let targetUserId = targetUserId else { return }

        isLoadingPosts = true

        do {
            let fetchedPosts = try await postService.getUserPosts(userId: targetUserId, limit: 50)
            self.posts = fetchedPosts

            print("✅ User posts loaded: \(fetchedPosts.count) posts")

        } catch {
            print("❌ Failed to load user posts: \(error)")
        }

        isLoadingPosts = false
    }

    // MARK: - Follow Actions

    /// フォローボタンがタップされた時の処理
    func handleFollowButtonTapped() async {
        guard let targetUserId = targetUserId,
              let currentUserId = currentUserId else { return }

        isFollowActionInProgress = true

        switch followStatus {
        case .notFollowing:
            // フォローリクエストを送信
            await sendFollowRequest()

        case .requestPending:
            // リクエストをキャンセル（実装は省略、将来的な拡張）
            // 現状では何もしない
            break

        case .following:
            // フォロー解除
            await unfollowUser()
        }

        isFollowActionInProgress = false
    }

    /// フォローリクエストを送信
    private func sendFollowRequest() async {
        guard let targetUserId = targetUserId,
              let currentUserId = currentUserId else { return }

        do {
            try await followService.sendFollowRequest(
                from: currentUserId,
                to: targetUserId
            )

            self.followStatus = .requestPending

            print("✅ Follow request sent")

        } catch {
            self.errorMessage = "フォローリクエストの送信に失敗しました"
            self.showError = true
            print("❌ Failed to send follow request: \(error)")
        }
    }

    /// フォロー解除
    private func unfollowUser() async {
        guard let targetUserId = targetUserId,
              let currentUserId = currentUserId else { return }

        do {
            try await followService.unfollow(
                followerId: currentUserId,
                followingId: targetUserId
            )

            self.followStatus = .notFollowing
            self.posts = [] // 投稿を非表示

            print("✅ Unfollowed user")

        } catch {
            self.errorMessage = "フォロー解除に失敗しました"
            self.showError = true
            print("❌ Failed to unfollow: \(error)")
        }
    }

    // MARK: - Refresh

    /// プロフィールを更新
    func refreshProfile() async {
        guard let targetUserId = targetUserId,
              let currentUserId = currentUserId else { return }
        await loadUserProfile(targetUserId: targetUserId, currentUserId: currentUserId)
    }

    // MARK: - Computed Properties

    /// 表示用のプロフィール画像URL
    var profileImageURL: String? {
        guard let url = userProfile?.profileImageURL else { return nil }
        return CloudinaryService.generateProfileImageURL(from: url, size: 150)
    }

    /// フォロワー数の表示
    var followersCountText: String {
        guard let count = userProfile?.followersCount else { return "0" }
        return "\(count)"
    }

    /// フォロー中の数の表示
    var followingCountText: String {
        guard let count = userProfile?.followingCount else { return "0" }
        return "\(count)"
    }

    /// 投稿数の表示
    var postsCountText: String {
        guard let count = userProfile?.postsCount else { return "0" }
        return "\(count)"
    }

    /// 自己紹介文（デフォルト）
    var bioText: String {
        return userProfile?.bio ?? "自己紹介はまだ設定されていません"
    }

    /// 投稿を表示できるかどうか（フォロー中の場合のみ）
    var canViewPosts: Bool {
        return followStatus == .following
    }

    /// 投稿が空かどうか
    var hasNoPosts: Bool {
        return posts.isEmpty && !isLoadingPosts && canViewPosts
    }

    /// 空の状態のメッセージ
    var emptyPostsMessage: String {
        if !canViewPosts {
            return "このユーザーをフォローすると投稿が表示されます"
        } else {
            return "まだ投稿がありません"
        }
    }
}
