//
//  ProfileViewModel.swift
//  Peephole
//
//  自分のプロフィール画面を管理するViewModel
//  プロフィール情報と投稿一覧の表示を担当
//

import Foundation
import SwiftUI
import Combine

@MainActor
class ProfileViewModel: ObservableObject {

    // MARK: - Published Properties

    /// プロフィール情報
    @Published var userProfile: FirestoreUser?

    /// 自分の投稿一覧
    @Published var posts: [FirestorePost] = []

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// 投稿読み込み中
    @Published var isLoadingPosts: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    // MARK: - Services

    private let userService = UserService.shared
    private let postService = PostService.shared
    private let cloudinaryService = CloudinaryService.shared

    // MARK: - Private Properties

    private var currentUserId: String?

    // MARK: - Load Profile

    /// プロフィール情報を読み込む
    /// - Parameter userId: 現在のユーザーID
    func loadProfile(userId: String) async {
        self.currentUserId = userId
        isLoading = true
        errorMessage = nil

        do {
            // プロフィール情報を取得
            let profile = try await userService.getUserProfile(userId: userId)
            self.userProfile = profile

            print("✅ Profile loaded: @\(profile.username)")

            // 投稿一覧も同時に読み込む
            await loadPosts()

        } catch {
            self.errorMessage = "プロフィールの読み込みに失敗しました"
            self.showError = true
            print("❌ Failed to load profile: \(error)")
        }

        isLoading = false
    }

    // MARK: - Load Posts

    /// 自分の投稿一覧を読み込む
    func loadPosts() async {
        guard let userId = currentUserId else { return }

        isLoadingPosts = true

        do {
            let fetchedPosts = try await postService.getUserPosts(userId: userId, limit: 50)
            self.posts = fetchedPosts

            print("✅ User posts loaded: \(fetchedPosts.count) posts")

        } catch {
            print("❌ Failed to load user posts: \(error)")
        }

        isLoadingPosts = false
    }

    // MARK: - Refresh Profile

    /// プロフィールを更新
    func refreshProfile() async {
        guard let userId = currentUserId else { return }
        await loadProfile(userId: userId)
    }

    // MARK: - Update Profile

    /// プロフィール情報を更新
    /// - Parameters:
    ///   - displayName: 表示名
    ///   - bio: 自己紹介
    func updateProfile(displayName: String?, bio: String?) async {
        guard let userId = currentUserId else { return }

        isLoading = true
        errorMessage = nil

        do {
            try await userService.updateUserProfile(
                userId: userId,
                displayName: displayName,
                bio: bio
            )

            // プロフィールを再読み込み
            await loadProfile(userId: userId)

            print("✅ Profile updated")

        } catch {
            self.errorMessage = "プロフィールの更新に失敗しました"
            self.showError = true
            print("❌ Failed to update profile: \(error)")
        }

        isLoading = false
    }

    // MARK: - Update Profile Image

    /// プロフィール画像を更新
    /// - Parameter image: 新しいプロフィール画像
    func updateProfileImage(_ image: UIImage) async {
        guard let userId = currentUserId else { return }

        isLoading = true
        errorMessage = nil

        do {
            // Cloudinaryにアップロード
            let imageURL = try await cloudinaryService.uploadProfileImage(image)

            // Firestoreに保存
            try await userService.updateUserProfile(
                userId: userId,
                profileImageURL: imageURL
            )

            // プロフィールを再読み込み
            await loadProfile(userId: userId)

            print("✅ Profile image updated: \(imageURL)")

        } catch {
            self.errorMessage = "プロフィール画像の更新に失敗しました"
            self.showError = true
            print("❌ Failed to update profile image: \(error)")
        }

        isLoading = false
    }

    // MARK: - Delete Post

    /// 投稿を削除
    /// - Parameter postId: 削除する投稿のID
    func deletePost(postId: String) async {
        guard let userId = currentUserId else { return }

        do {
            try await postService.deletePost(postId: postId, userId: userId)

            // ローカルの投稿一覧から削除
            self.posts.removeAll { $0.postId == postId }

            // プロフィールの投稿数を更新
            if let profile = userProfile {
                var updatedProfile = profile
                updatedProfile.postsCount = max(0, profile.postsCount - 1)
                self.userProfile = updatedProfile
            }

            print("✅ Post deleted: \(postId)")

        } catch {
            self.errorMessage = "投稿の削除に失敗しました"
            self.showError = true
            print("❌ Failed to delete post: \(error)")
        }
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

    // MARK: - Empty State

    /// 投稿が空かどうか
    var hasNoPosts: Bool {
        return posts.isEmpty && !isLoadingPosts
    }

    /// 空の状態のメッセージ
    var emptyPostsMessage: String {
        return "まだ投稿がありません"
    }
}
