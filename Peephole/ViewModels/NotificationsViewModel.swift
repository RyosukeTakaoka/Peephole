//
//  NotificationsViewModel.swift
//  Peephole
//
//  通知画面の表示を管理するViewModel
//  フォローリクエストの承認・拒否を担当
//

import Foundation
import SwiftUI
import Combine

@MainActor
class NotificationsViewModel: ObservableObject {

    // MARK: - Published Properties

    /// フォローリクエスト一覧
    @Published var followRequests: [FollowRequestWithUser] = []

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    /// 未読リクエスト数
    @Published var unreadCount: Int = 0

    // MARK: - Services

    private let followService = FollowService.shared
    private let userService = UserService.shared

    // MARK: - Private Properties

    private var currentUserId: String?

    // MARK: - Nested Model

    /// フォローリクエストとユーザー情報を結合したモデル
    struct FollowRequestWithUser: Identifiable {
        let id: String // requestId
        let request: FirestoreFollowRequest
        let requester: FirestoreUser // リクエスト送信者の情報
    }

    // MARK: - Load Follow Requests

    /// フォローリクエスト一覧を読み込む
    /// - Parameter userId: 現在のユーザーID
    func loadFollowRequests(userId: String) async {
        self.currentUserId = userId
        isLoading = true
        errorMessage = nil

        do {
            // フォローリクエストを取得
            let requests = try await followService.getPendingFollowRequests(targetId: userId)

            // 各リクエストの送信者情報を取得
            var requestsWithUser: [FollowRequestWithUser] = []

            for request in requests {
                do {
                    let requester = try await userService.getUserProfile(userId: request.requesterId)
                    requestsWithUser.append(
                        FollowRequestWithUser(
                            id: request.requestId,
                            request: request,
                            requester: requester
                        )
                    )
                } catch {
                    print("⚠️ Failed to fetch requester info for \(request.requesterId): \(error)")
                }
            }

            self.followRequests = requestsWithUser
            self.unreadCount = requestsWithUser.count

            print("✅ Follow requests loaded: \(requestsWithUser.count) requests")

        } catch {
            self.errorMessage = "フォローリクエストの読み込みに失敗しました"
            self.showError = true
            print("❌ Failed to load follow requests: \(error)")
        }

        isLoading = false
    }

    // MARK: - Approve Request

    /// フォローリクエストを承認
    /// - Parameter requestId: リクエストID
    func approveRequest(requestId: String) async {
        guard let userId = currentUserId else { return }

        do {
            try await followService.approveFollowRequest(
                requestId: requestId,
                currentUserId: userId
            )

            // ローカルの一覧から削除
            self.followRequests.removeAll { $0.id == requestId }
            self.unreadCount = self.followRequests.count

            print("✅ Follow request approved: \(requestId)")

        } catch {
            self.errorMessage = "フォローリクエストの承認に失敗しました"
            self.showError = true
            print("❌ Failed to approve request: \(error)")
        }
    }

    // MARK: - Reject Request

    /// フォローリクエストを拒否
    /// - Parameter requestId: リクエストID
    func rejectRequest(requestId: String) async {
        guard let userId = currentUserId else { return }

        do {
            try await followService.rejectFollowRequest(
                requestId: requestId,
                currentUserId: userId
            )

            // ローカルの一覧から削除
            self.followRequests.removeAll { $0.id == requestId }
            self.unreadCount = self.followRequests.count

            print("✅ Follow request rejected: \(requestId)")

        } catch {
            self.errorMessage = "フォローリクエストの拒否に失敗しました"
            self.showError = true
            print("❌ Failed to reject request: \(error)")
        }
    }

    // MARK: - Refresh

    /// リクエスト一覧を更新
    func refreshRequests() async {
        guard let userId = currentUserId else { return }
        await loadFollowRequests(userId: userId)
    }

    // MARK: - Empty State

    /// リクエストが空かどうか
    var isEmpty: Bool {
        return followRequests.isEmpty && !isLoading
    }

    /// 空の状態のメッセージ
    var emptyStateMessage: String {
        return "新しいフォローリクエストはありません"
    }

    // MARK: - Badge

    /// バッジ表示用の未読数
    var badgeCount: String {
        if unreadCount == 0 {
            return ""
        } else if unreadCount > 99 {
            return "99+"
        } else {
            return "\(unreadCount)"
        }
    }
}
