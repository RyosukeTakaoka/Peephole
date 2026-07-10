//
//  PeepholeWidget.swift
//  PeepholeWidget
//
//  Main widget implementation
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry
struct PeepholeWidgetEntry: TimelineEntry {
    let date: Date
    let posts: [Post]
    let displayIndex: Int // Which post(s) to display at this time

    // Calculate which posts to show based on widget family
    func postsToDisplay(for family: WidgetFamily) -> [Post] {
        guard !posts.isEmpty else { return [] }

        let count: Int
        switch family {
        case .systemSmall:
            count = 1
        case .systemMedium:
            count = 2
        case .systemLarge, .systemExtraLarge:
            count = 4
        @unknown default:
            count = 1
        }

        var result: [Post] = []
        for i in 0..<count {
            let index = (displayIndex + i) % posts.count
            result.append(posts[index])
        }
        return result
    }
}

// MARK: - Timeline Provider
struct PeepholeWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> PeepholeWidgetEntry {
        let mockData = SharedDataManager.generateMockData()
        return PeepholeWidgetEntry(date: Date(), posts: mockData.posts, displayIndex: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (PeepholeWidgetEntry) -> Void) {
        let data = SharedDataManager.loadWidgetData() ?? SharedDataManager.generateMockData()
        let entry = PeepholeWidgetEntry(date: Date(), posts: data.posts, displayIndex: 0)
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PeepholeWidgetEntry>) -> Void) {
        // Load data from shared container
        // 未ログイン・初回起動時などデータが無い場合は、モックではなく「投稿がありません」を表示する
        // （モックはリモートURLしか持たないため、新方式では永遠に灰色になり紛らわしい）
        guard let data = SharedDataManager.loadWidgetData(), !data.posts.isEmpty else {
            print("⚠️ [WIDGET] widgetData.jsonが無い、または投稿が空のため空状態を表示します")
            let entry = PeepholeWidgetEntry(date: Date(), posts: [], displayIndex: 0)
            let timeline = Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60)))
            completion(timeline)
            return
        }

        // Generate timeline entries for rotation
        // Each entry represents which posts to display at a specific time
        var entries: [PeepholeWidgetEntry] = []
        let currentDate = Date()
        let rotationInterval: TimeInterval = 30 * 60 // 30 minutes

        // Generate 24 hours worth of entries (48 entries × 30 min = 24 hours)
        for index in 0..<48 {
            let entryDate = currentDate.addingTimeInterval(TimeInterval(index) * rotationInterval)
            let displayIndex = index % data.posts.count
            let entry = PeepholeWidgetEntry(
                date: entryDate,
                posts: data.posts,
                displayIndex: displayIndex
            )
            entries.append(entry)
        }

        // Timeline policy: update after the last entry
        let nextUpdate = entries.last?.date ?? currentDate.addingTimeInterval(24 * 60 * 60)
        let timeline = Timeline(entries: entries, policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget View
struct PeepholeWidgetView: View {
    @Environment(\.widgetFamily) var family
    let entry: PeepholeWidgetEntry

    var body: some View {
        let postsToShow = entry.postsToDisplay(for: family)

        if postsToShow.isEmpty {
            EmptyWidgetView()
        } else {
            switch family {
            case .systemSmall:
                SmallWidgetView(post: postsToShow[0])
            case .systemMedium:
                MediumWidgetView(posts: postsToShow)
            case .systemLarge, .systemExtraLarge:
                LargeWidgetView(posts: postsToShow)
            @unknown default:
                SmallWidgetView(post: postsToShow[0])
            }
        }
    }
}

// MARK: - Empty State View
struct EmptyWidgetView: View {
    var body: some View {
        ZStack {
            Color(.systemGray6)

            VStack(spacing: 8) {
                Image(systemName: "eye.slash")
                    .font(.largeTitle)
                    .foregroundColor(.secondary)

                Text("投稿がありません")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            Color(.systemGray6)
        }
    }
}

// MARK: - Widget Configuration
struct PeepholeWidget: Widget {
    let kind: String = "PeepholeWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PeepholeWidgetProvider()) { entry in
            PeepholeWidgetView(entry: entry)
        }
        .configurationDisplayName("Peephole")
        .description("友達の「今」がホーム画面に流れてくる")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Preview
struct PeepholeWidget_Previews: PreviewProvider {
    static var previews: some View {
        let mockData = SharedDataManager.generateMockData()
        let entry = PeepholeWidgetEntry(date: Date(), posts: mockData.posts, displayIndex: 0)

        Group {
            PeepholeWidgetView(entry: entry)
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Small")

            PeepholeWidgetView(entry: entry)
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium")

            PeepholeWidgetView(entry: entry)
                .previewContext(WidgetPreviewContext(family: .systemLarge))
                .previewDisplayName("Large")
        }
    }
}
