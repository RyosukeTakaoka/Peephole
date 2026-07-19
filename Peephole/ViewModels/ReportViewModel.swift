//
//  ReportViewModel.swift
//  Peephole
//
//  通報フォームの状態管理と送信処理を担当
//

import Foundation
import SwiftUI
import Combine

@MainActor
class ReportViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 選択された通報理由
    @Published var selectedReason: ReportReason?

    /// 補足の詳細テキスト
    @Published var detail: String = ""

    /// 送信中フラグ
    @Published var isSubmitting: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    /// 送信完了フラグ
    @Published var reportSubmitted: Bool = false

    // MARK: - Services

    private let reportService = ReportService.shared

    // MARK: - Text Limits

    /// 詳細テキストの最大文字数
    let maxDetailLength = 500

    /// 詳細テキストが最大文字数を超えていないかチェック
    func validateDetailLength() {
        if detail.count > maxDetailLength {
            detail = String(detail.prefix(maxDetailLength))
        }
    }

    // MARK: - Submit

    /// 送信可能かどうか（理由が選択されていること）
    var canSubmit: Bool {
        return selectedReason != nil && !isSubmitting
    }

    /// 通報を送信する
    /// - Parameters:
    ///   - reporterId: 通報者のUID
    ///   - targetType: 通報対象の種別
    ///   - targetPostId: 対象投稿ID（投稿通報のとき必須）
    ///   - targetUserId: 対象ユーザーID
    func submitReport(
        reporterId: String,
        targetType: ReportTargetType,
        targetPostId: String?,
        targetUserId: String
    ) async {
        guard let reason = selectedReason else { return }

        isSubmitting = true
        errorMessage = nil

        let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            try await reportService.submitReport(
                reporterId: reporterId,
                targetType: targetType,
                targetPostId: targetPostId,
                targetUserId: targetUserId,
                reason: reason,
                detail: trimmedDetail.isEmpty ? nil : trimmedDetail
            )

            // 投稿通報の場合は通報者のローカル非表示リストにも追加する
            if targetType == .post, let postId = targetPostId {
                try await reportService.hidePost(userId: reporterId, postId: postId)
            }

            self.reportSubmitted = true
            print("✅ Report submitted successfully")

        } catch {
            self.errorMessage = "通報の送信に失敗しました"
            self.showError = true
            print("❌ Failed to submit report: \(error)")
        }

        isSubmitting = false
    }
}
