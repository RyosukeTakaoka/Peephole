//
//  HomeViewModel.swift
//  Peephole
//
//  ホーム画面（タイムライン）の表示を管理するViewModel
//  フォロー中のユーザーの投稿を取得・表示
//

import Foundation
import SwiftUI
import Combine

@MainActor
class HomeViewModel: ObservableObject {

    // MARK: - Published Properties

    /// タイムラインの投稿一覧
    @Published var posts: [FirestorePost] = []

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// リフレッシュ中かどうか
    @Published var isRefreshing: Bool = false

    /// さらに読み込み中（ページネーション）
    @Published var isLoadingMore: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    /// すべての投稿を読み込んだかどうか
    @Published var hasLoadedAll: Bool = false

    // MARK: - Services

    private let postService = PostService.shared
    private let followService = FollowService.shared

    // MARK: - Private Properties

    private var currentUserId: String?
    private let pageSize = 20

    // MARK: - Load Timeline

    /// タイムラインを読み込む（初回読み込み）
    /// - Parameter userId: 現在のユーザーID
    func loadTimeline(userId: String) async {
        self.currentUserId = userId
        isLoading = true
        errorMessage = nil
        hasLoadedAll = false

        do {
            // フォロー中のユーザーIDを取得
            let followingIds = try await followService.getFollowingIds(userId: userId)

            // 仕様: 自分の投稿もホームに表示する（フォロー中ユーザーの投稿と合わせて折衷案として正式採用）
            // ※ウィジェットには自分の投稿を流さないため、WidgetDataUpdater側でexcludingUserIdにより除外する
            var targetUserIds = followingIds
            if !targetUserIds.contains(userId) {
                targetUserIds.append(userId)
            }

            if targetUserIds.isEmpty {
                // フォローしているユーザーがいない場合（通常ありえない）
                self.posts = []
                self.hasLoadedAll = true
                self.isLoading = false
                return
            }

            // フォロー中のユーザー + 自分の投稿を取得
            let fetchedPosts = try await postService.getTimelinePosts(
                userIds: targetUserIds,
                limit: pageSize
            )

            self.posts = fetchedPosts
            self.hasLoadedAll = fetchedPosts.count < pageSize

            print("✅ Timeline loaded: \(fetchedPosts.count) posts")

            // タイムラインのデータをウィジェットにも反映（自分の投稿は除外）
            if !fetchedPosts.isEmpty {
                await WidgetDataUpdater.shared.updateWidgetWithTimelinePosts(firestorePosts: fetchedPosts, excludingUserId: userId)
            }

        } catch {
            self.errorMessage = "タイムラインの読み込みに失敗しました: \(error.localizedDescription)"
            self.showError = true
            print("❌ Failed to load timeline: \(error)")
        }

        isLoading = false
    }

    // MARK: - Refresh Timeline

    /// タイムラインを更新（Pull to Refresh用）
    func refreshTimeline() async {
        guard let userId = currentUserId else { return }

        isRefreshing = true
        errorMessage = nil
        hasLoadedAll = false

        do {
            // フォロー中のユーザーIDを取得
            let followingIds = try await followService.getFollowingIds(userId: userId)

            // 仕様: 自分の投稿もホームに表示する（フォロー中ユーザーの投稿と合わせて折衷案として正式採用）
            // ※ウィジェットには自分の投稿を流さないため、WidgetDataUpdater側でexcludingUserIdにより除外する
            var targetUserIds = followingIds
            if !targetUserIds.contains(userId) {
                targetUserIds.append(userId)
            }

            if targetUserIds.isEmpty {
                self.posts = []
                self.hasLoadedAll = true
                self.isRefreshing = false
                return
            }

            // フォロー中のユーザー + 自分の投稿を取得
            let fetchedPosts = try await postService.getTimelinePosts(
                userIds: targetUserIds,
                limit: pageSize
            )

            self.posts = fetchedPosts
            self.hasLoadedAll = fetchedPosts.count < pageSize

            print("✅ Timeline refreshed: \(fetchedPosts.count) posts")

            // タイムラインのデータをウィジェットにも反映（自分の投稿は除外）
            if !fetchedPosts.isEmpty {
                await WidgetDataUpdater.shared.updateWidgetWithTimelinePosts(firestorePosts: fetchedPosts, excludingUserId: userId)
            }

        } catch {
            self.errorMessage = "タイムラインの更新に失敗しました"
            self.showError = true
            print("❌ Failed to refresh timeline: \(error)")
        }

        isRefreshing = false
    }

    // MARK: - Load More Posts

    /// さらに投稿を読み込む（ページネーション）
    func loadMorePosts() async {
        guard let userId = currentUserId else { return }
        guard !isLoadingMore else { return }
        guard !hasLoadedAll else { return }

        isLoadingMore = true

        do {
            // フォロー中のユーザーIDを取得
            let followingIds = try await followService.getFollowingIds(userId: userId)

            // 仕様: 自分の投稿もホームに表示する（フォロー中ユーザーの投稿と合わせて折衷案として正式採用）
            var targetUserIds = followingIds
            if !targetUserIds.contains(userId) {
                targetUserIds.append(userId)
            }

            // 現在の最後の投稿の日時を取得（ページネーション用）
            // 注: Firestoreのページネーションは簡易実装（startAfterを使った実装は将来的な拡張）
            let currentCount = posts.count

            // 追加の投稿を取得
            let fetchedPosts = try await postService.getTimelinePosts(
                userIds: targetUserIds,
                limit: pageSize + currentCount
            )

            // 新しい投稿のみを追加
            let newPosts = Array(fetchedPosts.dropFirst(currentCount))

            if newPosts.isEmpty {
                self.hasLoadedAll = true
            } else {
                self.posts.append(contentsOf: newPosts)
                self.hasLoadedAll = newPosts.count < pageSize
            }

            print("✅ Loaded more posts: \(newPosts.count) new posts")

        } catch {
            print("❌ Failed to load more posts: \(error)")
        }

        isLoadingMore = false
    }

    // MARK: - Check if Should Load More

    /// 無限スクロールの判定（投稿が画面に表示された時に呼ばれる）
    /// - Parameter post: 表示された投稿
    func checkIfShouldLoadMore(for post: FirestorePost) {
        // 最後から3番目の投稿が表示されたら、さらに読み込む
        guard let lastPost = posts.dropLast(2).last else { return }

        if post.postId == lastPost.postId {
            Task {
                await loadMorePosts()
            }
        }
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

            print("✅ Post deleted: \(postId)")

        } catch {
            self.errorMessage = "投稿の削除に失敗しました"
            self.showError = true
            print("❌ Failed to delete post: \(error)")
        }
    }

    // MARK: - Empty State

    /// 投稿が空かどうか
    var isEmpty: Bool {
        return posts.isEmpty && !isLoading
    }

    /// 空の状態のメッセージ
    var emptyStateMessage: String {
        return "まだ投稿がありません\nユーザーをフォローして投稿を見てみましょう！"
    }
}
