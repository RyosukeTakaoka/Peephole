//
//  WidgetImageStore.swift
//  Peephole
//
//  App Group共有コンテナ内に、ウィジェット表示用の画像ファイルを保存/読込するユーティリティ
//  本体アプリ・ウィジェット両方から使われるため、Firebaseは一切importしない（Foundation + UIKitのみ）
//

import Foundation
import UIKit

enum WidgetImageStore {

    // MARK: - Directory

    /// App Group共有コンテナ内の画像保存ディレクトリ: {container}/WidgetImages/
    /// 存在しない場合は作成する
    static var imagesDirectoryURL: URL? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedDataManager.appGroupIdentifier
        ) else {
            print("❌ [IMAGE] App Group共有コンテナの取得に失敗しました: \(SharedDataManager.appGroupIdentifier)")
            return nil
        }

        let directoryURL = containerURL.appendingPathComponent("WidgetImages", isDirectory: true)

        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                print("✅ [IMAGE] WidgetImagesディレクトリを新規作成しました: \(directoryURL.path)")
            } catch {
                print("❌ [IMAGE] WidgetImagesディレクトリの作成に失敗しました: \(error)")
                return nil
            }
        }

        return directoryURL
    }

    // MARK: - File URL

    static func fileURL(for fileName: String) -> URL? {
        guard let directoryURL = imagesDirectoryURL else { return nil }
        return directoryURL.appendingPathComponent(fileName)
    }

    // MARK: - Exists Check

    static func fileExists(_ fileName: String) -> Bool {
        guard let url = fileURL(for: fileName) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Save

    /// 画像データをApp Group共有コンテナに保存する
    /// - Parameters:
    ///   - data: 保存する画像データ（JPEG想定）
    ///   - fileName: ファイル名（例: post_xxxx.jpg）
    /// - Returns: 保存に成功したかどうか
    @discardableResult
    static func save(_ data: Data, fileName: String) -> Bool {
        guard let url = fileURL(for: fileName) else {
            print("❌ [IMAGE] 保存先URLの取得に失敗: \(fileName)")
            return false
        }

        do {
            try data.write(to: url, options: .atomic)
            print("✅ [IMAGE] 画像を保存しました: \(fileName), サイズ: \(data.count) bytes")
            return true
        } catch {
            print("❌ [IMAGE] 画像の保存に失敗しました: \(fileName), error: \(error)")
            return false
        }
    }

    // MARK: - Load

    /// App Group共有コンテナから画像を同期読み込みする（ウィジェット用）
    /// - Parameter fileName: ファイル名
    /// - Returns: 読み込めたUIImage。ファイルが無い/破損している場合はnil
    static func loadImage(fileName: String) -> UIImage? {
        guard let url = fileURL(for: fileName) else {
            print("❌ [IMAGE] 画像読み込み: URLの取得に失敗: \(fileName)")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ [IMAGE] 画像読み込み: ファイルが存在しません: \(url.path)")
            return nil
        }

        guard let image = UIImage(contentsOfFile: url.path) else {
            print("❌ [IMAGE] 画像読み込み: UIImageの生成に失敗しました: \(url.path)")
            return nil
        }

        print("✅ [IMAGE] 画像を読み込みました: \(fileName), size: \(image.size)")
        return image
    }

    // MARK: - Cleanup

    /// 参照されなくなった古い画像ファイルを削除する
    /// - Parameter fileNames: 現在参照されている（残すべき）ファイル名の集合
    static func cleanup(keeping fileNames: Set<String>) {
        guard let directoryURL = imagesDirectoryURL else {
            print("❌ [IMAGE] クリーンアップ: ディレクトリの取得に失敗")
            return
        }

        do {
            let existingFiles = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )

            var deletedCount = 0
            for fileURL in existingFiles {
                let fileName = fileURL.lastPathComponent
                if !fileNames.contains(fileName) {
                    do {
                        try FileManager.default.removeItem(at: fileURL)
                        deletedCount += 1
                    } catch {
                        print("❌ [IMAGE] 古い画像ファイルの削除に失敗: \(fileName), error: \(error)")
                    }
                }
            }

            print("✅ [IMAGE] クリーンアップ完了: \(deletedCount)件の古い画像ファイルを削除しました（保持: \(fileNames.count)件）")
        } catch {
            print("❌ [IMAGE] クリーンアップ: ディレクトリの走査に失敗: \(error)")
        }
    }

    // MARK: - Remove All

    /// 保存済み画像を全て削除する（ログアウト時などに使用）
    static func removeAll() {
        guard let directoryURL = imagesDirectoryURL else {
            print("❌ [IMAGE] 全削除: ディレクトリの取得に失敗")
            return
        }

        do {
            let existingFiles = try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil
            )
            for fileURL in existingFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
            print("✅ [IMAGE] 全ての画像ファイルを削除しました: \(existingFiles.count)件")
        } catch {
            print("❌ [IMAGE] 全削除: ディレクトリの走査に失敗: \(error)")
        }
    }
}
