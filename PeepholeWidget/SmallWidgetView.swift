//
//  SmallWidgetView.swift
//  PeepholeWidget
//
//  Small widget view (1 person)
//

import SwiftUI
import WidgetKit

struct SmallWidgetView: View {
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

                // Gradient overlay for text readability
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.7)
                    ]),
                    startPoint: .center,
                    endPoint: .bottom
                )

                // Content overlay
                VStack(alignment: .leading, spacing: 4) {
                    // User info
                    HStack(spacing: 6) {
                        // Profile image（App Group共有コンテナからローカル読み込み）
                        if post.userProfileImageURL != nil {
                            WidgetLocalProfileImageView(
                                fileName: post.localProfileImageFileName,
                                size: 20
                            )
                        }

                        Text(post.userDisplayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }

                    // Post text
                    Text(post.text)
                        .font(.caption)
                        .foregroundColor(.white)
                        .lineLimit(2)

                    // Song info (if available)
                    if let song = post.song {
                        HStack(spacing: 4) {
                            Image(systemName: "music.note")
                                .font(.system(size: 10))
                            Text("\(song.title) - \(song.artist)")
                                .font(.system(size: 10))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(12)
            }
        }
        .widgetURL(URL(string: "peephole://post/\(post.id)"))
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

struct SmallWidgetView_Previews: PreviewProvider {
    static var previews: some View {
        let mockPost = Post(
            id: "1",
            userId: "user1",
            imageURL: "https://picsum.photos/400/400?random=1",
            text: "カフェでまったり☕️",
            song: Song(title: "Levitating", artist: "Dua Lipa"),
            createdAt: Date(),
            userName: "yuki_tanaka",
            userDisplayName: "Yuki",
            userProfileImageURL: "https://i.pravatar.cc/150?img=1"
        )

        SmallWidgetView(post: mockPost)
            .previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}
