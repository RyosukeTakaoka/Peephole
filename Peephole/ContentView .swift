//
//  ContentView.swift
//  Peephole
//
//  Main view of the app
//

import SwiftUI

struct ContentView: View {
    @State private var widgetData: WidgetData?
    @State private var selectedPostId: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Text("Peephole")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("友達の「今」を覗いてみよう")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Divider()
                    .padding(.vertical)

                // Display loaded data info
                if let data = widgetData {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ウィジェットデータ")
                            .font(.headline)

                        Text("投稿数: \(data.posts.count)")
                        Text("最終更新: \(formatDate(data.lastUpdated))")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button(action: refreshData) {
                            Label("データを更新", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)

                        // Display selected post ID from deep link
                        if let postId = selectedPostId {
                            Text("選択された投稿: \(postId)")
                                .font(.caption)
                                .foregroundColor(.blue)
                                .padding(.top, 4)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(12)
                } else {
                    Text("ウィジェットデータが見つかりません")
                        .foregroundColor(.secondary)
                }

                Spacer()

                VStack(spacing: 8) {
                    Text("ステップ1: ウィジェット開発中")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("次のステップで投稿機能とフォロー機能を実装します")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
            .padding()
            .navigationBarHidden(true)
        }
        .onAppear {
            loadData()
        }
        .onOpenURL { url in
            handleDeepLink(url)
        }
    }

    private func loadData() {
        widgetData = SharedDataManager.loadWidgetData()
    }

    private func refreshData() {
        let newData = SharedDataManager.generateMockData()
        SharedDataManager.saveWidgetData(newData)
        loadData()
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }

    private func handleDeepLink(_ url: URL) {
        // Handle deep link from widget
        // Format: peephole://post/{postId}
        guard url.scheme == "peephole" else { return }

        if url.host == "post" {
            let postId = url.pathComponents.dropFirst().first ?? ""
            selectedPostId = postId
            print("📱 Opened post from widget: \(postId)")

            // In the future, navigate to the post detail view
            // For now, just display the post ID
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
