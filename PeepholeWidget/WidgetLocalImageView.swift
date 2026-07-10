//
//  WidgetLocalImageView.swift
//  PeepholeWidget
//
//  App Group共有コンテナに保存済みのローカル画像を同期表示する共通View
//  AsyncImageはWidgetKitのレンダリング方式(同期・一回きり)と相性が悪いため使用しない
//

import SwiftUI
import WidgetKit
import UIKit

/// 投稿の背景画像用（矩形、fill表示）
struct WidgetLocalBackgroundImageView: View {
    let fileName: String?
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        if let fileName, let uiImage = WidgetImageStore.loadImage(fileName: fileName) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: width, height: height)
        } else {
            Color.gray.opacity(0.3)
                .overlay(
                    Image(systemName: "photo")
                        .foregroundColor(.white)
                )
        }
    }
}

/// プロフィール画像用（円形）
struct WidgetLocalProfileImageView: View {
    let fileName: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let fileName, let uiImage = WidgetImageStore.loadImage(fileName: fileName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.3))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
