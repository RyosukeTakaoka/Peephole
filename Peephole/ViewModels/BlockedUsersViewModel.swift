//
//  BlockedUsersViewModel.swift
//  Peephole
//
//  ブロック中ユーザー一覧画面を管理するViewModel
//  ブロック中ユーザーの取得と解除を担当
//

import Foundation
import SwiftUI
import Combine

@MainActor
class BlockedUsersViewModel: ObservableObject {

    // MARK: - Published Properties

    /// ブロック中ユーザー一覧
    @Published var blockedUsers: [BlockedUserInfo] = []

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    // MARK: - Services

    private let blockService = BlockService.shared
    private let userService = UserService.shared

    // MARK: - Private Properties

    private var currentUserId: String?

    // MARK: - Nested Model

    /// ブロックしたユーザーIDとプロフィール情報を結合したモデル
    /// プロフィール取得に失敗した場合（退会済み等）は user が nil になる
    struct BlockedUserInfo: Identifiable {
        let id: String // blockedId
        let user: FirestoreUser?
    }

    // MARK: - Load Blocked Users

    /// ブロック中ユーザー一覧を読み込む
    /// - Parameter userId: 現在のユーザーID
    func loadBlockedUsers(userId: String) async {
        self.currentUserId = userId
        isLoading = true
        errorMessage = nil

        do {
            let blockedIds = try await blockService.getBlockedIds(userId: userId)

            var infos: [BlockedUserInfo] = []
            for blockedId in blockedIds {
                // 退会したユーザー等でプロフィール取得に失敗しても行自体は表示する
                let user = try? await userService.getUserProfile(userId: blockedId)
                infos.append(BlockedUserInfo(id: blockedId, user: user))
            }

            self.blockedUsers = infos

            print("✅ Blocked users loaded: \(infos.count)")

        } catch {
            self.errorMessage = "ブロックしたユーザーの読み込みに失敗しました"
            self.showError = true
            print("❌ Failed to load blocked users: \(error)")
        }

        isLoading = false
    }

    // MARK: - Unblock User

    /// ブロックを解除する
    /// - Parameter blockedId: 解除対象のユーザーID
    func unblockUser(blockedId: String) async {
        guard let currentUserId = currentUserId else { return }

        do {
            try await blockService.unblockUser(blockerId: currentUserId, blockedId: blockedId)

            // ローカルの一覧から削除
            self.blockedUsers.removeAll { $0.id == blockedId }

            print("✅ Unblocked: \(blockedId)")

        } catch {
            self.errorMessage = "ブロック解除に失敗しました"
            self.showError = true
            print("❌ Failed to unblock user: \(error)")
        }
    }

    // MARK: - Refresh

    /// 一覧を更新
    func refresh() async {
        guard let userId = currentUserId else { return }
        await loadBlockedUsers(userId: userId)
    }

    // MARK: - Empty State

    /// ブロック中ユーザーが0件かどうか
    var isEmpty: Bool {
        return blockedUsers.isEmpty && !isLoading
    }

    /// 空の状態のメッセージ
    var emptyStateMessage: String {
        return "ブロックしたユーザーはいません"
    }
}
