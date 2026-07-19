//
//  UserSearchViewModel.swift
//  Peephole
//
//  ユーザー検索画面を管理するViewModel
//  ユーザー名の前方一致検索と自分自身の除外を担当
//

import Foundation
import SwiftUI
import Combine

@MainActor
class UserSearchViewModel: ObservableObject {

    // MARK: - Published Properties

    /// 検索クエリ
    @Published var query: String = ""

    /// 検索結果
    @Published var results: [FirestoreUser] = []

    /// ローディング状態
    @Published var isLoading: Bool = false

    /// 検索を一度でも実行したか（検索前の案内表示と0件表示を区別するため）
    @Published var hasSearched: Bool = false

    /// エラーメッセージ
    @Published var errorMessage: String?

    /// エラー表示フラグ
    @Published var showError: Bool = false

    // MARK: - Services

    private let userService = UserService.shared

    // MARK: - Search

    /// ユーザー名の前方一致で検索し、自分自身を結果から除外する
    /// - Parameters:
    ///   - query: 検索クエリ（ユーザー名の前方一致）
    ///   - currentUserId: 現在のユーザーID（結果から除外する）
    func search(query: String, currentUserId: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return }

        isLoading = true
        errorMessage = nil

        do {
            let users = try await userService.searchUsers(query: trimmedQuery)
            self.results = users.filter { $0.userId != currentUserId }
            self.hasSearched = true

            print("✅ User search completed: \(self.results.count) results")

        } catch {
            self.errorMessage = "検索に失敗しました"
            self.showError = true
            print("❌ Failed to search users: \(error)")
        }

        isLoading = false
    }

    // MARK: - Empty State

    /// 検索結果が0件かどうか（検索実行済みかつ結果なし）
    var isEmptyResult: Bool {
        return hasSearched && !isLoading && results.isEmpty
    }
}
