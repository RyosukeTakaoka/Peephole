//
//  LargeWidgetView.swift
//  PeepholeWidget
//
//  Large widget view (4 people in a 2x2 grid)
//

import SwiftUI
import WidgetKit

struct LargeWidgetView: View {
    let posts: [Post]

    var body: some View {
        VStack(spacing: 2) {
            // Top row (2 posts)
            HStack(spacing: 2) {
                if posts.count > 0 {
                    CompactPostCardView(post: posts[0])
                }
                if posts.count > 1 {
                    CompactPostCardView(post: posts[1])
                }
            }

            // Bottom row (2 posts)
            HStack(spacing: 2) {
                if posts.count > 2 {
                    CompactPostCardView(post: posts[2])
                }
                if posts.count > 3 {
                    CompactPostCardView(post: posts[3])
                }
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

// MARK: - Compact Post Card View (for Large widget grid)
struct CompactPostCardView: View {
    let post: Post

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                // Background image（App Group共有コンテナからローカル読み込み）
                WidgetLocalBackgroundImageView(
                    fileName: post.localImageFileName,
                    width: geometry.size.width,
                    height: geometry.size.height
                )
                .clipped()

                // Gradient overlay
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.75)
                    ]),
                    startPoint: .center,
                    endPoint: .bottom
                )

                // Content
                VStack(alignment: .leading, spacing: 2) {
                    // User info
                    HStack(spacing: 3) {
                        if post.userProfileImageURL != nil {
                            WidgetLocalProfileImageView(
                                fileName: post.localProfileImageFileName,
                                size: 14
                            )
                        }

                        Text(post.userDisplayName)
                            .font(.system(size: 10))
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }

                    // Post text
                    Text(post.text)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    // Song info
                    if let song = post.song {
                        HStack(spacing: 2) {
                            Image(systemName: "music.note")
                                .font(.system(size: 7))
                            Text(song.title)
                                .font(.system(size: 8))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white.opacity(0.85))
                    }
                }
                .padding(6)
            }
        }
        .widgetURL(URL(string: "peephole://post/\(post.id)"))
    }
}

struct LargeWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        let mockPosts = [
            Post(
                id: "1",
                userId: "user1",
                imageURL: "https://picsum.photos/400/400?random=1",
                text: "カフェでまったり☕️",
                song: Song(title: "Levitating", artist: "Dua Lipa"),
                createdAt: Date(),
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
                createdAt: Date(),
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
                createdAt: Date(),
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
                createdAt: Date(),
                userName: "kenji_yamada",
                userDisplayName: "Kenji",
                userProfileImageURL: "https://i.pravatar.cc/150?img=4"
            )
        ]

        LargeWidgetView(posts: mockPosts)
            .previewContext(WidgetPreviewContext(family: .systemLarge))
    }
}
