//
//  WidgetDataUpdater.swift
//  Peephole
//
//  本体アプリ専用: Firestoreから投稿を取得してウィジェットデータを更新
//  Firebase依存の処理を含むため、ウィジェットとは共有しない
//
//  仕様: ホーム画面には自分の投稿も表示するが、ウィジェットにはフォロー中ユーザーの投稿のみを流す
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
            // フォロー中のユーザーIDを取得（ウィジェットには自分の投稿は含めない）
            let followingIds = try await followService.getFollowingIds(userId: userId)

            if followingIds.isEmpty {
                print("⚠️ [WIDGET] フォロー中のユーザーがいないため、空データを保存します")
                await publishWidgetData(from: [], excludingUserId: userId)
                return
            }

            // フォロー中のユーザーの投稿を取得（ウィジェット用に最大6件）
            let firestorePosts = try await postService.getTimelinePosts(userIds: followingIds, limit: 6)

            await publishWidgetData(from: firestorePosts, excludingUserId: userId)

            print("✅ [WIDGET] Widget updated with following posts: \(firestorePosts.count) posts")
        } catch {
            print("❌ [WIDGET] Failed to update widget with following posts: \(error)")
        }
    }

    // MARK: - Update Widget with Timeline Posts

    /// タイムラインの投稿でウィジェットデータを更新
    /// - Parameters:
    ///   - firestorePosts: Firestoreから取得した投稿一覧（自分の投稿を含む場合がある）
    ///   - excludingUserId: ウィジェットから除外するユーザーID（通常は自分自身）
    func updateWidgetWithTimelinePosts(firestorePosts: [FirestorePost], excludingUserId: String) async {
        print("🔵 [WIDGET] Updating widget data from timeline...")

        await publishWidgetData(from: firestorePosts, excludingUserId: excludingUserId)

        print("✅ [WIDGET] Widget data updated")
    }

    // MARK: - Publish Widget Data (Shared Pipeline)

    /// 画像準備 → JSON保存 → 古いファイルの掃除 → リロード、を順序を守って実行する
    /// - Note: 処理順序が重要。JSONを先に書くと、ウィジェットがreload前に起きた場合に
    ///   存在しないファイルを参照してしまう。「画像保存 → JSON保存 → cleanup → reload」を厳守する。
    /// - Parameters:
    ///   - firestorePosts: 元となる投稿一覧
    ///   - excludingUserId: ウィジェットから除外するユーザーID（自分自身の投稿はウィジェットに出さない仕様）
    private func publishWidgetData(from firestorePosts: [FirestorePost], excludingUserId: String) async {
        // 自分の投稿を除外してから先頭6件に絞る
        let targetPosts = Array(firestorePosts.filter { $0.userId != excludingUserId }.prefix(6))
        print("🔵 [WIDGET] publishWidgetData: 対象\(targetPosts.count)件（除外前\(firestorePosts.count)件, excludingUserId=\(excludingUserId)）")

        // 1. 画像をダウンロード・保存し、ローカル参照付きのPost配列を取得
        let widgetPosts = await imagePreparer.preparePosts(from: targetPosts)

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
