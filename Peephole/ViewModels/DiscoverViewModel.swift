//
//  DiscoverViewModel.swift
//  Peephole
//
//  発見（ユーザー検索）画面を管理するViewModel
//  ユーザー名の前方一致検索を担当
//

import Foundation
import SwiftUI
import Combine

@MainActor
class DiscoverViewModel: ObservableObject {

    // MARK: - Published Properties

    @Published var searchText: String = ""
    @Published var results: [FirestoreUser] = []
    @Published var isSearching: Bool = false
    /// 「結果なし」と「未検索」の表示分岐用
    @Published var hasSearched: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false

    // MARK: - Services

    private let userService = UserService.shared

    // MARK: - Search

    /// 検索実行。呼び出し側(.task(id:))でデバウンス済み
    /// - Parameter currentUserId: 現在のユーザーID（検索結果から自分を除外するために使用）
    func search(currentUserId: String) async {
        // トリム・先頭@除去・小文字化して正規化（UserService側でも正規化するが、空判定のためここでも整形する）
        var normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.hasPrefix("@") {
            normalizedQuery.removeFirst()
        }
        normalizedQuery = normalizedQuery.lowercased()

        guard !normalizedQuery.isEmpty else {
            print("🔵 [DISCOVER] 検索クエリが空のため結果をクリア")
            results = []
            hasSearched = false
            return
        }

        print("🔵 [DISCOVER] ユーザー検索を開始: クエリ=\"\(normalizedQuery)\"")
        isSearching = true

        do {
            let searchResults = try await userService.searchUsers(query: normalizedQuery)

            // デバウンスキャンセル対応: 検索中にキャンセルされていたら結果を反映しない
            guard !Task.isCancelled else {
                print("⚠️ [DISCOVER] 検索がキャンセルされたため結果を破棄: クエリ=\"\(normalizedQuery)\"")
                isSearching = false
                return
            }

            // 自分自身を除外
            let filteredResults = searchResults.filter { $0.userId != currentUserId }

            self.results = filteredResults
            self.hasSearched = true

            print("✅ [DISCOVER] ユーザー検索完了: \(filteredResults.count)件（自分を除外前: \(searchResults.count)件）")
        } catch {
            print("❌ [DISCOVER] ユーザー検索に失敗: \(error)")
            self.errorMessage = "検索に失敗しました"
            self.results = []
            self.hasSearched = true
        }

        isSearching = false
    }
}
