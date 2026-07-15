//
//  PostCreateViewModel.swift
//  Peephole
//
//  投稿作成のフローを管理するViewModel
//  写真選択、画像アップロード、投稿作成を担当
//

import Foundation
import SwiftUI
import UIKit
import PhotosUI
import Combine

@MainActor
class PostCreateViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 選択された画像（SwiftUI用）
    @Published var selectedImage: UIImage?

    /// 投稿テキスト
    @Published var postText: String = ""

    /// 曲のタイトル
    @Published var songTitle: String = ""

    /// アーティスト名
    @Published var songArtist: String = ""

    /// 曲情報を追加するかどうか
    @Published var includeSong: Bool = false

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// アップロード進行状況（0.0〜1.0）
    @Published var uploadProgress: Double = 0.0

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    /// 投稿成功フラグ
    @Published var postCreated: Bool = false

    // MARK: - Services

    private let cloudinaryService = CloudinaryService.shared
    private let postService = PostService.shared
    private let userService = UserService.shared
    private let moderationService = ModerationService.shared

    // MARK: - Create Post

    /// 投稿を作成
    /// - Parameter currentUserId: 現在のユーザーID
    func createPost(currentUserId: String) async {
        // バリデーション
        guard let image = selectedImage else {
            showErrorMessage("写真を選択してください")
            return
        }

        guard !postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showErrorMessage("投稿テキストを入力してください")
            return
        }

        // NGワードチェック（アップロード前に検証する）
        guard !moderationService.containsProhibitedWord(postText) else {
            showErrorMessage("不適切な表現が含まれているため投稿できません")
            return
        }

        // 曲情報のバリデーション（追加する場合）
        if includeSong {
            guard !songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showErrorMessage("曲名を入力してください")
                return
            }
            guard !songArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                showErrorMessage("アーティスト名を入力してください")
                return
            }
        }

        isLoading = true
        uploadProgress = 0.0
        errorMessage = nil

        do {
            // ステップ1: Cloudinaryに画像をアップロード
            uploadProgress = 0.3
            let imageURL = try await cloudinaryService.uploadPostImage(image)
            print("✅ Image uploaded: \(imageURL)")

            // ステップ2: ユーザー情報を取得（非正規化用）
            uploadProgress = 0.6
            let userProfile = try await userService.getUserProfile(userId: currentUserId)

            // ステップ3: 曲情報を作成（オプショナル）
            let song: FirestoreSong? = includeSong ? FirestoreSong(
                title: songTitle.trimmingCharacters(in: .whitespacesAndNewlines),
                artist: songArtist.trimmingCharacters(in: .whitespacesAndNewlines),
                spotifyId: nil
            ) : nil

            // ステップ4: Firestoreに投稿を作成
            uploadProgress = 0.9
            let postId = try await postService.createPost(
                userId: currentUserId,
                imageURL: imageURL,
                text: postText.trimmingCharacters(in: .whitespacesAndNewlines),
                song: song,
                userInfo: (
                    username: userProfile.username,
                    displayName: userProfile.displayName,
                    profileImageURL: userProfile.profileImageURL
                )
            )

            uploadProgress = 1.0
            print("✅ Post created: \(postId)")

            // ステップ5: ウィジェットデータを更新
            await updateWidgetData(userId: currentUserId)

            // 成功: 状態をリセット
            postCreated = true
            resetForm()

        } catch let error as CloudinaryError {
            showErrorMessage(error.errorDescription ?? "画像のアップロードに失敗しました")
        } catch let error as PostServiceError {
            showErrorMessage(error.errorDescription ?? "投稿の作成に失敗しました")
        } catch {
            showErrorMessage("予期しないエラーが発生しました: \(error.localizedDescription)")
        }

        isLoading = false
        uploadProgress = 0.0
    }

    // MARK: - Image Selection

    /// PhotosPickerから画像を選択（SwiftUI PhotosPicker用）
    func selectImage(from result: PhotosPickerItem?) async {
        guard let result = result else { return }

        do {
            if let data = try await result.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                self.selectedImage = uiImage
                print("✅ Image selected")
            }
        } catch {
            showErrorMessage("画像の読み込みに失敗しました")
        }
    }

    /// UIImagePickerから画像を選択（UIKit用）
    func setImage(_ image: UIImage) {
        self.selectedImage = image
        print("✅ Image set")
    }

    // MARK: - Form Validation

    /// 投稿可能かどうか
    var canPost: Bool {
        guard selectedImage != nil else { return false }
        guard !postText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        if includeSong {
            guard !songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            guard !songArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        }

        return true
    }

    // MARK: - Reset

    /// フォームをリセット
    func resetForm() {
        selectedImage = nil
        postText = ""
        songTitle = ""
        songArtist = ""
        includeSong = false
        errorMessage = nil
        showError = false
        uploadProgress = 0.0
    }

    // MARK: - Error Handling

    /// エラーメッセージを表示
    private func showErrorMessage(_ message: String) {
        self.errorMessage = message
        self.showError = true
        print("❌ Error: \(message)")
    }

    // MARK: - Widget Update

    /// ウィジェットデータを更新（フォロー中のユーザーの投稿を含む）
    /// - Parameter userId: 現在のユーザーID
    private func updateWidgetData(userId: String) async {
        // WidgetDataUpdater（本体アプリ専用）を使用
        // フォロー中のユーザー + 自分の投稿をウィジェットに表示
        await WidgetDataUpdater.shared.updateWidgetWithFollowingPosts(userId: userId)
    }

    // MARK: - Text Limits

    /// 投稿テキストの最大文字数
    let maxTextLength = 100

    /// 曲名の最大文字数
    let maxSongTitleLength = 50

    /// アーティスト名の最大文字数
    let maxArtistLength = 50

    /// テキストが最大文字数を超えていないかチェック
    func validateTextLength() {
        if postText.count > maxTextLength {
            postText = String(postText.prefix(maxTextLength))
        }
    }

    /// 曲名が最大文字数を超えていないかチェック
    func validateSongTitleLength() {
        if songTitle.count > maxSongTitleLength {
            songTitle = String(songTitle.prefix(maxSongTitleLength))
        }
    }

    /// アーティスト名が最大文字数を超えていないかチェック
    func validateArtistLength() {
        if songArtist.count > maxArtistLength {
            songArtist = String(songArtist.prefix(maxArtistLength))
        }
    }
}
