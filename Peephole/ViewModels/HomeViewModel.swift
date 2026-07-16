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
    private let blockService = BlockService.shared
    private let reportService = ReportService.shared

    // MARK: - Private Properties

    private var currentUserId: String?
    private let pageSize = 20

    // MARK: - Resolve Target User Ids

    /// タイムライン取得対象のユーザーID一覧（フォロー中 + 自分、ブロック関係にあるユーザーを除外）を解決
    /// - Parameter userId: 現在のユーザーID
    private func resolveTargetUserIds(for userId: String) async throws -> [String] {
        // フォロー中のユーザーIDを取得
        let followingIds = try await followService.getFollowingIds(userId: userId)

        // 【TODO: 動作確認用の一時的な変更】
        // 自分自身の投稿もタイムラインに表示する
        // 本番環境では、フォロー中のユーザーの投稿のみを表示する設計に戻す
        var targetUserIds = followingIds
        if !targetUserIds.contains(userId) {
            targetUserIds.append(userId)
        }

        // ブロック関係にあるユーザー（自分がブロックした/自分をブロックした双方向）を除外
        let blockedIds = try await blockService.getBlockedIds(userId: userId)
        let blockerIds = try await blockService.getBlockerIds(userId: userId)
        let excludedIds = Set(blockedIds).union(blockerIds)

        return targetUserIds.filter { !excludedIds.contains($0) }
    }

    // MARK: - Filter Hidden Posts

    /// 通報によって非表示にした投稿を除外する
    /// - Parameters:
    ///   - posts: フィルタ対象の投稿一覧
    ///   - userId: 現在のユーザーID
    private func filterHiddenPosts(_ posts: [FirestorePost], for userId: String) async -> [FirestorePost] {
        guard let hiddenPostIds = try? await reportService.getHiddenPostIds(userId: userId),
              !hiddenPostIds.isEmpty else {
            return posts
        }

        let hiddenSet = Set(hiddenPostIds)
        return posts.filter { !hiddenSet.contains($0.postId) }
    }

    // MARK: - Load Timeline

    /// タイムラインを読み込む（初回読み込み）
    /// - Parameter userId: 現在のユーザーID
    func loadTimeline(userId: String) async {
        self.currentUserId = userId
        isLoading = true
        errorMessage = nil
        hasLoadedAll = false

        do {
            // タイムライン取得対象のユーザーID（ブロック関係を除外）を解決
            let targetUserIds = try await resolveTargetUserIds(for: userId)

            if targetUserIds.isEmpty {
                // フォローしているユーザーがいない場合（通常ありえない）
                self.posts = []
                self.hasLoadedAll = true
                self.isLoading = false
                return
            }

            // フォロー中のユーザー + 自分の投稿を取得
            let rawPosts = try await postService.getTimelinePosts(
                userIds: targetUserIds,
                limit: pageSize
            )

            // 通報して非表示にした投稿を除外
            let fetchedPosts = await filterHiddenPosts(rawPosts, for: userId)

            self.posts = fetchedPosts
            self.hasLoadedAll = fetchedPosts.count < pageSize

            print("✅ Timeline loaded: \(fetchedPosts.count) posts")

            // ウィジェットにも反映（画像ダウンロードを伴うためバックグラウンドで実行。
            // T21で updateWidgetWithFollowingPosts に一本化）
            if !fetchedPosts.isEmpty {
                Task {
                    await WidgetDataUpdater.shared.updateWidgetWithFollowingPosts(userId: userId)
                }
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
            // タイムライン取得対象のユーザーID（ブロック関係を除外）を解決
            let targetUserIds = try await resolveTargetUserIds(for: userId)

            if targetUserIds.isEmpty {
                self.posts = []
                self.hasLoadedAll = true
                self.isRefreshing = false
                return
            }

            // フォロー中のユーザー + 自分の投稿を取得
            let rawPosts = try await postService.getTimelinePosts(
                userIds: targetUserIds,
                limit: pageSize
            )

            // 通報して非表示にした投稿を除外
            let fetchedPosts = await filterHiddenPosts(rawPosts, for: userId)

            self.posts = fetchedPosts
            self.hasLoadedAll = fetchedPosts.count < pageSize

            print("✅ Timeline refreshed: \(fetchedPosts.count) posts")

            // ウィジェットにも反映（画像ダウンロードを伴うためバックグラウンドで実行。
            // T21で updateWidgetWithFollowingPosts に一本化）
            if !fetchedPosts.isEmpty {
                Task {
                    await WidgetDataUpdater.shared.updateWidgetWithFollowingPosts(userId: userId)
                }
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
            // タイムライン取得対象のユーザーID（ブロック関係を除外）を解決
            let targetUserIds = try await resolveTargetUserIds(for: userId)

            // 現在の最後の投稿の日時を取得（ページネーション用）
            // 注: Firestoreのページネーションは簡易実装（startAfterを使った実装は将来的な拡張）
            let currentCount = posts.count

            // 追加の投稿を取得
            let rawPosts = try await postService.getTimelinePosts(
                userIds: targetUserIds,
                limit: pageSize + currentCount
            )

            // 通報して非表示にした投稿を除外
            let fetchedPosts = await filterHiddenPosts(rawPosts, for: userId)

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

    // MARK: - Report Post

    /// 通報済みの投稿をローカルの一覧から即時除去する
    /// - Parameter postId: 通報した投稿のID
    func removeReportedPost(postId: String) {
        self.posts.removeAll { $0.postId == postId }
        print("✅ Reported post removed from timeline: \(postId)")
    }

    // MARK: - Block User

    /// タイムライン上のユーザーをブロックする
    /// - Parameter userId: ブロック対象のユーザーID
    func blockUser(userId: String) async {
        guard let currentUserId = currentUserId else { return }

        do {
            try await blockService.blockUser(blockerId: currentUserId, blockedId: userId)

            // ローカルの投稿一覧から該当ユーザーの投稿を即時除去
            self.posts.removeAll { $0.userId == userId }

            print("✅ User blocked from timeline: \(userId)")

            // ウィジェットデータを再生成
            await WidgetDataUpdater.shared.updateWidgetWithFollowingPosts(userId: currentUserId)

        } catch {
            self.errorMessage = "ブロックに失敗しました"
            self.showError = true
            print("❌ Failed to block user: \(error)")
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
