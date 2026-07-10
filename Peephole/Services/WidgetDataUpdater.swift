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
    private let imagePreparer = WidgetImagePreparer.shared

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

            await publishWidgetData(from: firestorePosts)

            print("✅ [WIDGET] Widget updated with following posts: \(firestorePosts.count) posts")
        } catch {
            print("❌ [WIDGET] Failed to update widget with following posts: \(error)")
        }
    }

    // MARK: - Update Widget with Timeline Posts

    /// タイムラインの投稿でウィジェットデータを更新
    /// - Parameter firestorePosts: Firestoreから取得した投稿一覧
    func updateWidgetWithTimelinePosts(firestorePosts: [FirestorePost]) async {
        guard !firestorePosts.isEmpty else {
            print("⚠️ [WIDGET] No posts to update widget")
            return
        }

        print("🔵 [WIDGET] Updating widget data from timeline...")

        await publishWidgetData(from: firestorePosts)

        print("✅ [WIDGET] Widget data updated: \(firestorePosts.count) posts")
    }

    // MARK: - Publish Widget Data (Shared Pipeline)

    /// 画像準備 → JSON保存 → 古いファイルの掃除 → リロード、を順序を守って実行する
    /// - Note: 処理順序が重要。JSONを先に書くと、ウィジェットがreload前に起きた場合に
    ///   存在しないファイルを参照してしまう。「画像保存 → JSON保存 → cleanup → reload」を厳守する。
    private func publishWidgetData(from firestorePosts: [FirestorePost]) async {
        // 1. 画像をダウンロード・保存し、ローカル参照付きのPost配列を取得
        let widgetPosts = await imagePreparer.preparePosts(from: firestorePosts)

        // 2. widgetData.json をApp Groupに保存
        let widgetData = WidgetData(posts: widgetPosts, lastUpdated: Date())
        SharedDataManager.saveWidgetData(widgetData)

        // 3. 参照中のファイル名を集めて、古い画像ファイルを掃除
        var keepFileNames = Set<String>()
        for post in widgetPosts {
            if let fileName = post.localImageFileName {
                keepFileNames.insert(fileName)
            }
            if let fileName = post.localProfileImageFileName {
                keepFileNames.insert(fileName)
            }
        }
        WidgetImageStore.cleanup(keeping: keepFileNames)

        // 4. ウィジェットのタイムラインをリロード
        SharedDataManager.reloadWidget()
    }
}
