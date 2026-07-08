//
//  WidgetDataUpdater.swift
//  Peephole
//
//  本体アプリ専用: Firestoreから投稿を取得してウィジェットデータを更新
//  Firebase依存の処理を含むため、ウィジェットとは共有しない
//

import Foundation

class WidgetDataUpdater {

    // MARK: - Singleton
    static let shared = WidgetDataUpdater()

    private let followService = FollowService.shared
    private let postService = PostService.shared

    private init() {}

    // MARK: - Update Widget with Following Posts

    /// フォロー中のユーザーの投稿を取得してウィジェットデータを更新
    /// - Parameter userId: 現在のユーザーID
    func updateWidgetWithFollowingPosts(userId: String) async {
        print("🔵 [WIDGET] Fetching following posts for widget...")

        do {
            // フォロー中のユーザーIDを取得
            let followingIds = try await followService.getFollowingIds(userId: userId)

            // 【動作確認用】自分自身のIDも追加（HomeViewModelと同じロジック）
            var targetUserIds = followingIds
            if !targetUserIds.contains(userId) {
                targetUserIds.append(userId)
            }

            if targetUserIds.isEmpty {
                print("⚠️ [WIDGET] No users to fetch posts from")
                return
            }

            // フォロー中のユーザー + 自分の投稿を取得（ウィジェット用に最大6件）
            let firestorePosts = try await postService.getTimelinePosts(userIds: targetUserIds, limit: 6)

            // FirestorePost → Post に変換
            let widgetPosts = firestorePosts.map { $0.toPost() }

            // ウィジェット用データを作成
            let widgetData = WidgetData(posts: widgetPosts, lastUpdated: Date())

            // App Groups に保存
            SharedDataManager.saveWidgetData(widgetData)

            // ウィジェットのタイムラインをリロード
            SharedDataManager.reloadWidget()

            print("✅ [WIDGET] Widget updated with following posts: \(widgetPosts.count) posts")
        } catch {
            print("❌ [WIDGET] Failed to update widget with following posts: \(error)")
        }
    }

    // MARK: - Update Widget with Timeline Posts

    /// タイムラインの投稿でウィジェットデータを更新
    /// - Parameter firestorePosts: Firestoreから取得した投稿一覧
    func updateWidgetWithTimelinePosts(firestorePosts: [FirestorePost]) {
        guard !firestorePosts.isEmpty else {
            print("⚠️ [WIDGET] No posts to update widget")
            return
        }

        print("🔵 [WIDGET] Updating widget data from timeline...")

        // FirestorePost → Post に変換
        let widgetPosts = firestorePosts.map { $0.toPost() }

        // ウィジェット用データを作成
        let widgetData = WidgetData(posts: widgetPosts, lastUpdated: Date())

        // App Groups に保存
        SharedDataManager.saveWidgetData(widgetData)

        // ウィジェットのタイムラインをリロード
        SharedDataManager.reloadWidget()

        print("✅ [WIDGET] Widget data updated: \(widgetPosts.count) posts")
    }
}
