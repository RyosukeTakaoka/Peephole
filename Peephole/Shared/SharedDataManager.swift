//
//  SharedDataManager.swift
//  Peephole
//
//  Manages data sharing between app and widget via App Groups
//

import Foundation
#if !APPCLIP
import WidgetKit
#endif

class SharedDataManager {
    // MARK: - App Group Configuration
    // NOTE: You need to create this App Group in Xcode:
    // 1. Select your target → Signing & Capabilities → + Capability → App Groups
    // 2. Add the group identifier below for both the app and widget targets
    static let appGroupIdentifier = "group.app.takaoka.com.peephole.shared"

    private static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    private static var widgetDataURL: URL? {
        sharedContainerURL?.appendingPathComponent("widgetData.json")
    }

    // MARK: - Save Data
    static func saveWidgetData(_ data: WidgetData) {
        guard let url = widgetDataURL else {
            print("❌ Failed to get shared container URL")
            return
        }

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let jsonData = try encoder.encode(data)
            try jsonData.write(to: url, options: .atomic)
            print("✅ Widget data saved successfully")
        } catch {
            print("❌ Failed to save widget data: \(error)")
        }
    }

    // MARK: - Load Data
    static func loadWidgetData() -> WidgetData? {
        guard let url = widgetDataURL else {
            print("❌ Failed to get shared container URL")
            return nil
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("⚠️ Widget data file does not exist yet")
            return nil
        }

        do {
            let jsonData = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let data = try decoder.decode(WidgetData.self, from: jsonData)
            print("✅ Widget data loaded successfully")
            return data
        } catch {
            print("❌ Failed to load widget data: \(error)")
            return nil
        }
    }

    // MARK: - Clear Data
    /// ウィジェットデータを削除する（ログアウト時・アカウント削除時に呼び出す）
    /// 他人のデータがウィジェットに残る問題を防ぐ
    static func clearWidgetData() {
        guard let url = widgetDataURL else {
            print("❌ Failed to get shared container URL")
            return
        }

        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                print("✅ Widget data cleared")
            } catch {
                print("❌ Failed to clear widget data: \(error)")
            }
        }

        reloadWidget()
    }

    // MARK: - Widget Timeline Reload
    /// ウィジェットの表示を更新（タイムラインをリロード）
    /// 本体アプリ側から呼び出される
    static func reloadWidget() {
        #if !APPCLIP
        WidgetCenter.shared.reloadAllTimelines()
        print("✅ [WIDGET] Widget timeline reloaded")
        #endif
    }

    // MARK: - Mock Data Generator (for development)
    static func generateMockData() -> WidgetData {
        let mockPosts = [
            Post(
                id: "1",
                userId: "user1",
                imageURL: "https://picsum.photos/400/400?random=1",
                text: "カフェでまったり☕️",
                song: Song(title: "Levitating", artist: "Dua Lipa"),
                createdAt: Date().addingTimeInterval(-3600), // 1 hour ago
                userName: "yuki_tanaka",
                userDisplayName: "Yuki",
                userProfileImageURL: "https://i.pravatar.cc/150?img=1"
            ),
            Post(
                id: "2",
                userId: "user2",
                imageURL: "https://picsum.photos/400/400?random=2",
                text: "今日も良い天気🌞",
                song: nil,
                createdAt: Date().addingTimeInterval(-7200), // 2 hours ago
                userName: "takeshi_sato",
                userDisplayName: "Takeshi",
                userProfileImageURL: "https://i.pravatar.cc/150?img=2"
            ),
            Post(
                id: "3",
                userId: "user3",
                imageURL: "https://picsum.photos/400/400?random=3",
                text: "ランチタイム🍜",
                song: Song(title: "Blinding Lights", artist: "The Weeknd"),
                createdAt: Date().addingTimeInterval(-10800), // 3 hours ago
                userName: "mika_suzuki",
                userDisplayName: "Mika",
                userProfileImageURL: "https://i.pravatar.cc/150?img=3"
            ),
            Post(
                id: "4",
                userId: "user4",
                imageURL: "https://picsum.photos/400/400?random=4",
                text: "新しい本を買った📚",
                song: Song(title: "Good Days", artist: "SZA"),
                createdAt: Date().addingTimeInterval(-14400), // 4 hours ago
                userName: "kenji_yamada",
                userDisplayName: "Kenji",
                userProfileImageURL: "https://i.pravatar.cc/150?img=4"
            ),
            Post(
                id: "5",
                userId: "user5",
                imageURL: "https://picsum.photos/400/400?random=5",
                text: "夕焼けがきれい🌅",
                song: nil,
                createdAt: Date().addingTimeInterval(-18000), // 5 hours ago
                userName: "aoi_nakamura",
                userDisplayName: "Aoi",
                userProfileImageURL: "https://i.pravatar.cc/150?img=5"
            ),
            Post(
                id: "6",
                userId: "user6",
                imageURL: "https://picsum.photos/400/400?random=6",
                text: "ジムで筋トレ💪",
                song: Song(title: "Save Your Tears", artist: "The Weeknd"),
                createdAt: Date().addingTimeInterval(-21600), // 6 hours ago
                userName: "ryo_ishida",
                userDisplayName: "Ryo",
                userProfileImageURL: "https://i.pravatar.cc/150?img=6"
            )
        ]

        return WidgetData(posts: mockPosts, lastUpdated: Date())
    }
}
