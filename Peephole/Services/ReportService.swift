//
//  ReportService.swift
//  Peephole
//
//  通報機能のビジネスロジック
//  通報の作成、通報者ローカルの非表示リスト（hiddenPosts）の読み書きを担当
//

import Foundation
import FirebaseFirestore

// MARK: - Report Target Type
enum ReportTargetType: String, Codable {
    case post
    case user
}

// MARK: - Report Reason
enum ReportReason: String, Codable, CaseIterable {
    case inappropriateContent
    case harassment
    case spam
    case impersonation
    case other

    var displayName: String {
        switch self {
        case .inappropriateContent:
            return "不適切なコンテンツ（性的・暴力的など）"
        case .harassment:
            return "嫌がらせ・いじめ"
        case .spam:
            return "スパム"
        case .impersonation:
            return "なりすまし"
        case .other:
            return "その他"
        }
    }
}

// MARK: - Report Model
struct FirestoreReport: Codable, Identifiable {
    let reportId: String
    let reporterId: String        // 通報者
    let targetType: String        // "post" | "user"
    let targetPostId: String?     // targetType == "post" のとき必須
    let targetUserId: String      // 投稿通報でも投稿者のIDを常に保持
    let reason: String            // ReportReason の rawValue
    let detail: String?           // 任意の補足（最大500文字）
    var status: String            // "pending" | "reviewed" | "actioned"
    var notified: Bool            // 開発者通知済みフラグ
    let createdAt: Date

    // Identifiable準拠のため、reportIdをidとして使用
    var id: String { reportId }
}

// MARK: - Hidden Post Model
struct FirestoreHiddenPost: Codable, Identifiable {
    let postId: String
    let hiddenAt: Date

    var id: String { postId }
}

enum ReportServiceError: LocalizedError {
    case invalidData
    case unknown(String)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "通報データが不正です"
        case .unknown(let message):
            return "エラーが発生しました: \(message)"
        }
    }
}

class ReportService {

    // MARK: - Singleton
    static let shared = ReportService()

    private let db = FirebaseManager.shared.db
    private let reportsCollection: CollectionReference
    private let usersCollection = FirebaseManager.shared.usersCollection

    private init() {
        self.reportsCollection = db.collection("reports")
    }

    // MARK: - Submit Report
    /// 通報を作成する（初期状態は status = "pending" / notified = false）
    /// - Parameters:
    ///   - reporterId: 通報者のUID
    ///   - targetType: 通報対象の種別（投稿 / ユーザー）
    ///   - targetPostId: 対象投稿ID（targetType == .post のとき必須）
    ///   - targetUserId: 対象ユーザーID（投稿通報でも投稿者のIDを保持）
    ///   - reason: 通報理由
    ///   - detail: 任意の補足テキスト
    func submitReport(
        reporterId: String,
        targetType: ReportTargetType,
        targetPostId: String?,
        targetUserId: String,
        reason: ReportReason,
        detail: String?
    ) async throws {
        let newReportRef = reportsCollection.document()
        let report = FirestoreReport(
            reportId: newReportRef.documentID,
            reporterId: reporterId,
            targetType: targetType.rawValue,
            targetPostId: targetPostId,
            targetUserId: targetUserId,
            reason: reason.rawValue,
            detail: detail,
            status: "pending",
            notified: false,
            createdAt: Date()
        )

        do {
            try newReportRef.setData(from: report)
            print("✅ Report submitted: \(newReportRef.documentID)")
        } catch {
            throw ReportServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Hide Post
    /// 通報者ローカルの非表示リストに投稿を追加する
    /// - Parameters:
    ///   - userId: 通報者（非表示にする本人）のUID
    ///   - postId: 非表示にする投稿ID
    func hidePost(userId: String, postId: String) async throws {
        let hiddenPostRef = usersCollection.document(userId)
            .collection("hiddenPosts")
            .document(postId)

        do {
            try await hiddenPostRef.setData([
                "postId": postId,
                "hiddenAt": FieldValue.serverTimestamp()
            ])
            print("✅ Post hidden: \(postId) for user \(userId)")
        } catch {
            throw ReportServiceError.unknown(error.localizedDescription)
        }
    }

    // MARK: - Get Hidden Post Ids
    /// 通報者ローカルの非表示リストに含まれる投稿IDの一覧を取得
    /// - Parameter userId: ユーザーID
    /// - Returns: 非表示にした投稿IDのリスト
    func getHiddenPostIds(userId: String) async throws -> [String] {
        do {
            let querySnapshot = try await usersCollection.document(userId)
                .collection("hiddenPosts")
                .getDocuments()

            return querySnapshot.documents.map { $0.documentID }
        } catch {
            throw ReportServiceError.unknown(error.localizedDescription)
        }
    }
}
