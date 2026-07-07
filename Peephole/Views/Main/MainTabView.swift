//
//  MainTabView.swift
//  Peephole
//
//  メインアプリのタブバー構成
//  ホーム、発見、投稿、通知、プロフィールの5つのタブ
//

import SwiftUI

struct MainTabView: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @StateObject private var notificationsViewModel = NotificationsViewModel()

    @State private var selectedTab = 0
    @State private var showPostCreate = false

    var body: some View {
        TabView(selection: $selectedTab) {
            // 1. ホーム（タイムライン）
            NavigationStack {
                HomeScreen()
            }
            .tabItem {
                Label("ホーム", systemImage: selectedTab == 0 ? "house.fill" : "house")
            }
            .tag(0)

            // 2. 発見（ユーザー検索）- 将来的な実装
            NavigationStack {
                DiscoverPlaceholderScreen()
            }
            .tabItem {
                Label("発見", systemImage: selectedTab == 1 ? "magnifyingglass.circle.fill" : "magnifyingglass")
            }
            .tag(1)

            // 3. 投稿作成（モーダル表示）
            Color.clear
                .tabItem {
                    Label("投稿", systemImage: "plus.circle.fill")
                }
                .tag(2)

            // 4. 通知
            NavigationStack {
                NotificationsScreen()
            }
            .tabItem {
                Label("通知", systemImage: selectedTab == 3 ? "bell.fill" : "bell")
            }
            .badge(notificationsViewModel.unreadCount)
            .tag(3)

            // 5. プロフィール
            NavigationStack {
                ProfileScreen()
            }
            .tabItem {
                Label("プロフィール", systemImage: selectedTab == 4 ? "person.fill" : "person")
            }
            .tag(4)
        }
        .onChange(of: selectedTab) { _, newValue in
            // 投稿タブがタップされたらモーダルを表示
            if newValue == 2 {
                showPostCreate = true
                // タブを元に戻す
                selectedTab = 0
            }
        }
        .sheet(isPresented: $showPostCreate) {
            NavigationStack {
                PostCreateScreen()
            }
        }
        .environmentObject(notificationsViewModel)
        .task {
            // 通知の未読数を取得
            if let userId = authViewModel.currentUserId {
                await notificationsViewModel.loadFollowRequests(userId: userId)
            }
        }
    }
}

// MARK: - Discover Placeholder Screen

struct DiscoverPlaceholderScreen: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("発見")
                .font(.system(size: 24, weight: .bold))

            Text("ユーザー検索機能は\n今後実装予定です")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .navigationTitle("発見")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthViewModel())
}
