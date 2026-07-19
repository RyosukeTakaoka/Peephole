//
//  MediumWidgetView.swift
//  PeepholeWidget
//
//  Medium widget view (2 people side by side)
//

import SwiftUI
import WidgetKit

struct MediumWidgetView: View {
    let posts: [Post]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(posts.prefix(2)) { post in
                PostCardView(post: post)
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

// MARK: - Post Card View (reusable for Medium widget)
struct PostCardView: View {
    let post: Post

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                // Background image
                // T21: 事前ダウンロード済みのローカル画像を優先（WidgetKitではAsyncImageの
                // ネットワーク取得が保証されないため）。無い場合のみAsyncImageにフォールバック
                Group {
                    if let fileName = post.localImageFileName,
                       let uiImage = SharedDataManager.loadWidgetImage(fileName: fileName) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    } else {
                        AsyncImage(url: URL(string: post.imageURL)) { phase in
                            switch phase {
                            case .empty:
                                Color.gray.opacity(0.3)
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            case .failure:
                                Color.gray.opacity(0.3)
                                    .overlay(
                                        Image(systemName: "photo")
                                            .foregroundColor(.white)
                                    )
                            @unknown default:
                                Color.gray.opacity(0.3)
                            }
                        }
                    }
                }
                .clipped()

                // Gradient overlay
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0),
                        Color.black.opacity(0.7)
                    ]),
                    startPoint: .center,
                    endPoint: .bottom
                )

                // Content
                VStack(alignment: .leading, spacing: 3) {
                    // User info
                    HStack(spacing: 4) {
                        if let profileURL = post.userProfileImageURL {
                            Group {
                                if let fileName = post.localProfileImageFileName,
                                   let uiImage = SharedDataManager.loadWidgetImage(fileName: fileName) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } else {
                                    AsyncImage(url: URL(string: profileURL)) { phase in
                                        if let image = phase.image {
                                            image
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                        } else {
                                            Circle()
                                                .fill(Color.white.opacity(0.3))
                                        }
                                    }
                                }
                            }
                            .frame(width: 16, height: 16)
                            .clipShape(Circle())
                        }

                        Text(post.userDisplayName)
                            .font(.system(size: 11))
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                    }

                    // Post text
                    Text(post.text)
                        .font(.system(size: 11))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    // Song info
                    if let song = post.song {
                        HStack(spacing: 2) {
                            Image(systemName: "music.note")
                                .font(.system(size: 8))
                            Text("\(song.title)")
                                .font(.system(size: 9))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white.opacity(0.9))
                    }
                }
                .padding(8)
            }
        }
        .widgetURL(URL(string: "peephole://post/\(post.id)"))
    }
}

struct MediumWidgetView_Previews: PreviewProvider {
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
            )
        ]

        MediumWidgetView(posts: mockPosts)
            .previewContext(WidgetPreviewContext(family: .systemMedium))
    }
}
