//
//  CloudinaryService.swift
//  Peephole
//
//  Cloudinaryへの画像アップロード処理
//  投稿画像とプロフィール画像のアップロードを担当
//

import Foundation
import UIKit

enum CloudinaryError: LocalizedError {
    case invalidImage
    case uploadFailed(String)
    case invalidResponse
    case networkError

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "画像の処理に失敗しました"
        case .uploadFailed(let message):
            return "アップロードに失敗しました: \(message)"
        case .invalidResponse:
            return "サーバーからの応答が不正です"
        case .networkError:
            return "ネットワークエラーが発生しました"
        }
    }
}

class CloudinaryService {

    // MARK: - Singleton
    static let shared = CloudinaryService()

    // MARK: - Cloudinary Configuration
    private let cloudName = "dw71feikq"
    private let uploadPresetPosts = "peephole_posts"
    private let uploadPresetProfiles = "peephole_profiles"

    private init() {}

    // MARK: - Upload Post Image
    /// 投稿画像をCloudinaryにアップロード
    /// - Parameter image: UIImage
    /// - Returns: アップロードされた画像のURL（オリジナル）
    func uploadPostImage(_ image: UIImage) async throws -> String {
        return try await uploadImage(
            image,
            uploadPreset: uploadPresetPosts,
            folder: "peephole/posts"
        )
    }

    // MARK: - Upload Profile Image
    /// プロフィール画像をCloudinaryにアップロード
    /// - Parameter image: UIImage
    /// - Returns: アップロードされた画像のURL（オリジナル）
    func uploadProfileImage(_ image: UIImage) async throws -> String {
        return try await uploadImage(
            image,
            uploadPreset: uploadPresetProfiles,
            folder: "peephole/profiles"
        )
    }

    // MARK: - Private Upload Method
    /// 画像をCloudinaryにアップロード
    private func uploadImage(
        _ image: UIImage,
        uploadPreset: String,
        folder: String
    ) async throws -> String {
        // 画像をリサイズ（最大1080px）
        let resizedImage = resizeImage(image, maxWidth: 1080)

        // JPEG形式に変換
        guard let imageData = resizedImage.jpegData(compressionQuality: 0.8) else {
            throw CloudinaryError.invalidImage
        }

        // Cloudinary Upload URLを構築
        let uploadURL = "https://api.cloudinary.com/v1_1/\(cloudName)/image/upload"

        // リクエストを作成
        var request = URLRequest(url: URL(string: uploadURL)!)
        request.httpMethod = "POST"

        // マルチパートフォームデータを作成
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // upload_preset
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"upload_preset\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(uploadPreset)\r\n".data(using: .utf8)!)

        // folder
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"folder\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(folder)\r\n".data(using: .utf8)!)

        // public_id（ユニークなID）
        let publicId = UUID().uuidString
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"public_id\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(publicId)\r\n".data(using: .utf8)!)

        // file（画像データ）
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"image.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        // 終了境界
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        // アップロードを実行
        do {
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CloudinaryError.invalidResponse
            }

            guard httpResponse.statusCode == 200 else {
                let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                throw CloudinaryError.uploadFailed(errorMessage)
            }

            // レスポンスをパース
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let secureUrl = json["secure_url"] as? String else {
                throw CloudinaryError.invalidResponse
            }

            print("✅ Image uploaded to Cloudinary: \(secureUrl)")
            return secureUrl

        } catch let error as CloudinaryError {
            throw error
        } catch {
            throw CloudinaryError.networkError
        }
    }

    // MARK: - Image Resize
    /// 画像をリサイズ
    private func resizeImage(_ image: UIImage, maxWidth: CGFloat) -> UIImage {
        let scale = maxWidth / image.size.width
        if scale >= 1 {
            return image // リサイズ不要
        }

        let newHeight = image.size.height * scale
        let newSize = CGSize(width: maxWidth, height: newHeight)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return resizedImage ?? image
    }

    // MARK: - Generate Thumbnail URL
    /// CloudinaryのオリジナルURLからサムネイルURLを生成
    /// - Parameters:
    ///   - originalURL: オリジナル画像URL
    ///   - width: サムネイル幅
    ///   - height: サムネイル高さ
    /// - Returns: サムネイルURL
    static func generateThumbnailURL(
        from originalURL: String,
        width: Int = 400,
        height: Int = 400
    ) -> String {
        // Cloudinary URLの構造: https://res.cloudinary.com/{cloud_name}/image/upload/{transformations}/{public_id}.jpg
        // 変換パラメータを /upload/ の直後に挿入

        guard originalURL.contains("cloudinary.com/"),
              let uploadRange = originalURL.range(of: "/upload/") else {
            return originalURL
        }

        let transformations = "w_\(width),h_\(height),c_fill,q_auto,f_auto"
        let insertIndex = uploadRange.upperBound
        var transformedURL = originalURL
        transformedURL.insert(contentsOf: transformations + "/", at: insertIndex)

        return transformedURL
    }

    // MARK: - Generate Profile Image URL
    /// プロフィール画像のURL（顔認識クロップ付き）
    static func generateProfileImageURL(
        from originalURL: String,
        size: Int = 150
    ) -> String {
        guard originalURL.contains("cloudinary.com/"),
              let uploadRange = originalURL.range(of: "/upload/") else {
            return originalURL
        }

        let transformations = "w_\(size),h_\(size),c_fill,g_face,q_auto,f_auto"
        let insertIndex = uploadRange.upperBound
        var transformedURL = originalURL
        transformedURL.insert(contentsOf: transformations + "/", at: insertIndex)

        return transformedURL
    }
}

// MARK: - String Extension for Cloudinary URL
extension String {
    /// Cloudinary変換URLを生成
    func cloudinaryURL(width: Int, height: Int? = nil, crop: String = "fill") -> String {
        guard self.contains("cloudinary.com/"),
              let uploadRange = self.range(of: "/upload/") else {
            return self
        }

        var transformations = "w_\(width)"
        if let height = height {
            transformations += ",h_\(height),c_\(crop)"
        } else {
            transformations += ",c_limit"
        }
        transformations += ",q_auto,f_auto"

        let insertIndex = uploadRange.upperBound
        var transformedURL = self
        transformedURL.insert(contentsOf: transformations + "/", at: insertIndex)

        return transformedURL
    }
}
