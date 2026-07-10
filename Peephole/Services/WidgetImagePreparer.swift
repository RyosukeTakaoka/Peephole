//
//  WidgetImagePreparer.swift
//  Peephole
//
//  本体アプリ専用: 投稿画像・プロフィール画像をCloudinaryからダウンロードし、
//  App Group共有コンテナへ保存した上で、ローカルファイル名を持つPost配列を返す
//  Firebase依存の処理を含むため、ウィジェットとは共有しない
//

import Foundation
import UIKit

class WidgetImagePreparer {

    // MARK: - Singleton
    static let shared = WidgetImagePreparer()

    private init() {}

    // MARK: - Constants

    /// 1件あたりの画像ダウンロードのタイムアウト（秒）
    private let downloadTimeout: TimeInterval = 15
    /// 保存前の防御的検証: この長辺(px)を超えたら再リサイズする
    private let maxAcceptableDimension: CGFloat = 600
    /// 保存前の防御的検証: このバイト数を超えたら再リサイズする
    private let maxAcceptableBytes = 500 * 1024
    /// 再リサイズ時のターゲットサイズ(px)
    private let resizeTargetSize: CGFloat = 400

    // MARK: - Prepare Posts

    /// 各投稿の画像を共有コンテナへ準備し、ローカル参照付きのPost配列を返す
    /// - Parameter firestorePosts: Firestoreから取得した投稿一覧（呼び出し元で6件以内に絞られている想定）
    /// - Returns: localImageFileName / localProfileImageFileName が入ったPost配列
    func preparePosts(from firestorePosts: [FirestorePost]) async -> [Post] {
        // 二重防御: 呼び出し元でも制限しているが、ここでも最大6件に絞る
        let targetPosts = Array(firestorePosts.prefix(6))
        print("🔵 [IMAGE] ウィジェット用画像の準備を開始: 対象\(targetPosts.count)件")

        var resultPosts = [Post?](repeating: nil, count: targetPosts.count)

        await withTaskGroup(of: (Int, Post).self) { group in
            for (index, firestorePost) in targetPosts.enumerated() {
                group.addTask { [weak self] in
                    guard let self else {
                        return (index, firestorePost.toPost())
                    }
                    let post = await self.preparePost(firestorePost)
                    return (index, post)
                }
            }

            for await (index, post) in group {
                resultPosts[index] = post
            }
        }

        let finalPosts = resultPosts.compactMap { $0 }
        print("✅ [IMAGE] ウィジェット用画像の準備が完了: \(finalPosts.count)件")
        return finalPosts
    }

    // MARK: - Prepare Single Post

    private func preparePost(_ firestorePost: FirestorePost) async -> Post {
        let postFileName = "post_\(firestorePost.postId).jpg"
        let profileFileName: String? = firestorePost.userProfileImageURL != nil
            ? "profile_\(firestorePost.userId).jpg"
            : nil

        // 投稿画像: 既にファイルがあればダウンロードをスキップ（投稿は編集不可なので内容も同じ）
        if WidgetImageStore.fileExists(postFileName) {
            print("🔵 [IMAGE] キャッシュヒット、ダウンロードをスキップ: \(postFileName)")
        } else {
            await downloadAndSaveImage(
                from: firestorePost.imageURL,
                size: 400,
                fileName: postFileName,
                context: "post(\(firestorePost.postId))"
            )
        }

        // プロフィール画像: 差し替わる可能性があるため毎回上書きダウンロード
        if let profileFileName, let profileURL = firestorePost.userProfileImageURL {
            await downloadAndSaveImage(
                from: profileURL,
                size: 150,
                fileName: profileFileName,
                context: "profile(\(firestorePost.userId))"
            )
        }

        // DL成否に関わらず、処理後にファイルが存在すればファイル名を使う
        // （失敗しても過去のファイルが残っていればそれを参照し続けることで、オフライン時に画像が消えるのを防ぐ）
        let finalImageFileName = WidgetImageStore.fileExists(postFileName) ? postFileName : nil
        let finalProfileFileName: String?
        if let profileFileName {
            finalProfileFileName = WidgetImageStore.fileExists(profileFileName) ? profileFileName : nil
        } else {
            finalProfileFileName = nil
        }

        return firestorePost.toPost(
            localImageFileName: finalImageFileName,
            localProfileImageFileName: finalProfileFileName
        )
    }

    // MARK: - Download & Save

    /// 画像をダウンロードし、必要なら再エンコードして保存する
    /// 失敗しても例外は投げず、ログのみ残して処理を続行する（呼び出し元は既存ファイルの有無で成否を判断する）
    private func downloadAndSaveImage(from originalURL: String, size: Int, fileName: String, context: String) async {
        let widgetImageURLString = CloudinaryService.generateWidgetImageURL(from: originalURL, size: size)

        guard let url = URL(string: widgetImageURLString) else {
            print("❌ [IMAGE] 不正なURLのためダウンロードをスキップ: \(context), url: \(widgetImageURLString)")
            return
        }

        print("🔵 [IMAGE] 画像のダウンロードを開始: \(context), url: \(widgetImageURLString)")

        var request = URLRequest(url: url)
        request.timeoutInterval = downloadTimeout

        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                print("🔵 [IMAGE] レスポンス受信: \(context), status: \(httpResponse.statusCode), サイズ: \(data.count) bytes")
                guard httpResponse.statusCode == 200 else {
                    print("❌ [IMAGE] 画像のダウンロードに失敗（HTTPエラー）: \(context), status: \(httpResponse.statusCode)")
                    return
                }
            }

            guard let image = UIImage(data: data) else {
                print("❌ [IMAGE] 画像のダウンロードに失敗（デコード不可）: \(context)")
                return
            }

            let finalData = normalizedData(for: image, originalData: data)

            if WidgetImageStore.save(finalData, fileName: fileName) {
                print("✅ [IMAGE] 画像を保存しました: \(context) → \(fileName), サイズ: \(finalData.count) bytes")
            } else {
                print("❌ [IMAGE] 画像の保存に失敗しました: \(context) → \(fileName)")
            }
        } catch {
            print("❌ [IMAGE] 画像のダウンロードに失敗: \(context), error: \(error)")
        }
    }

    /// 保存前の防御的検証: 長辺600px超 または 500KB超の場合のみ400pxに再リサイズ・再エンコードする
    private func normalizedData(for image: UIImage, originalData: Data) -> Data {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxAcceptableDimension || originalData.count > maxAcceptableBytes else {
            return originalData
        }

        print("⚠️ [IMAGE] 想定より大きい画像を検出、再リサイズします: size=\(image.size), bytes=\(originalData.count)")

        let resized = resizeImage(image, maxDimension: resizeTargetSize)
        guard let jpegData = resized.jpegData(compressionQuality: 0.7) else {
            print("⚠️ [IMAGE] 再エンコードに失敗、元データをそのまま使用します")
            return originalData
        }
        return jpegData
    }

    private func resizeImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longSide = max(image.size.width, image.size.height)
        guard longSide > maxDimension else { return image }

        let scale = maxDimension / longSide
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
