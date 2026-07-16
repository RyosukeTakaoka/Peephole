//
//  WidgetDataUpdater.swift
//  Peephole
//
//  本体アプリ専用: Firestoreから投稿を取得してウィジェットデータを更新
//  Firebase依存の処理を含むため、ウィジェットとは共有しない
//
//  T21: WidgetKitはスナップショット描画のためウィジェット内のAsyncImageによる
//  ネットワーク取得が保証されない。本クラスで投稿画像・プロフィール画像を
//  事前ダウンロードしてApp Groupに保存し、ウィジェットはローカル読み込みで描画する。
//

import Foundation
import UIKit

class WidgetDataUpdater {

    // MARK: - Singleton
    static let shared = WidgetDataUpdater()

    private let followService = FollowService.shared
    private let postService = PostService.shared
    private let blockService = BlockService.shared
    private let reportService = ReportService.shared

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

            // ブロック関係にあるユーザー（双方向）を除外
            // フォロー解除で通常は消えるが、書き込み競合への防御として明示的に除外する
            let blockedIds = try await blockService.getBlockedIds(userId: userId)
            let blockerIds = try await blockService.getBlockerIds(userId: userId)
            let excludedIds = Set(blockedIds).union(blockerIds)
            targetUserIds = targetUserIds.filter { !excludedIds.contains($0) }

            if targetUserIds.isEmpty {
                print("⚠️ [WIDGET] No users to fetch posts from")
                return
            }

            // フォロー中のユーザー + 自分の投稿を取得（ウィジェット用に最大6件）
            let rawPosts = try await postService.getTimelinePosts(userIds: targetUserIds, limit: 6)

            // 通報して非表示にした投稿を除外
            let hiddenPostIds = try await reportService.getHiddenPostIds(userId: userId)
            let hiddenSet = Set(hiddenPostIds)
            let firestorePosts = rawPosts.filter { !hiddenSet.contains($0.postId) }

            // 画像を事前ダウンロードし、ローカルファイル名付きの Post に変換（T21）
            let widgetPosts = await downloadImagesAndConvert(firestorePosts)

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

    // MARK: - Image Pre-download

    /// 各投稿のサムネイル・プロフィール画像をApp Groupにダウンロードし、
    /// ローカルファイル名を持つ Post 配列に変換する
    private func downloadImagesAndConvert(_ firestorePosts: [FirestorePost]) async -> [Post] {
        var widgetPosts: [Post] = []
        var keepFileNames = Set<String>()

        for post in firestorePosts {
            // 投稿サムネイル（投稿ごとにURL不変のため、保存済みならスキップ）
            let imageFileName = await downloadImageIfNeeded(
                from: post.thumbnailURL,
                fileName: "\(post.postId).jpg"
            )

            // プロフィール画像（小さい変換URLを使用）
            var profileFileName: String?
            if let profileURL = post.userProfileImageURL {
                let resizedURL = CloudinaryService.generateProfileImageURL(from: profileURL, size: 100)
                profileFileName = await downloadImageIfNeeded(
                    from: resizedURL,
                    fileName: "\(post.postId)_profile.jpg"
                )
            }

            if let fileName = imageFileName {
                keepFileNames.insert(fileName)
            }
            if let fileName = profileFileName {
                keepFileNames.insert(fileName)
            }

            widgetPosts.append(post.toPost(
                localImageFileName: imageFileName,
                localProfileImageFileName: profileFileName
            ))
        }

        // 表示対象から外れた投稿の画像を掃除
        SharedDataManager.pruneWidgetImages(keeping: keepFileNames)

        return widgetPosts
    }

    /// 画像をダウンロードしてApp Groupに保存し、成功時はファイル名を返す
    /// 保存済みの場合はダウンロードをスキップする。失敗時は nil（ウィジェットはプレースホルダ表示）
    private func downloadImageIfNeeded(from urlString: String, fileName: String) async -> String? {
        if SharedDataManager.widgetImageExists(fileName: fileName) {
            return fileName
        }

        guard let url = URL(string: urlString),
              let directory = SharedDataManager.ensureWidgetImagesDirectory() else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  UIImage(data: data) != nil else {
                print("❌ [WIDGET] Image download failed (invalid response): \(urlString)")
                return nil
            }

            try data.write(to: directory.appendingPathComponent(fileName), options: .atomic)
            print("✅ [WIDGET] Image downloaded: \(fileName)")
            return fileName
        } catch {
            print("❌ [WIDGET] Image download failed: \(error)")
            return nil
        }
    }
}
