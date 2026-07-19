//
//  Models.swift
//  Peephole
//
//  Shared models between app and widget
//  2026/7/7

import Foundation

// MARK: - User Model
struct PeepholeUser: Codable, Identifiable {
    let id: String
    let username: String
    let displayName: String
    let profileImageURL: String?

    init(id: String, username: String, displayName: String, profileImageURL: String? = nil) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.profileImageURL = profileImageURL
    }
}

// MARK: - Song Model
struct Song: Codable {
    let title: String
    let artist: String

    init(title: String, artist: String) {
        self.title = title
        self.artist = artist
    }
}

// MARK: - Post Model
struct Post: Codable, Identifiable {
    let id: String
    let userId: String
    let imageURL: String
    let text: String
    let song: Song?
    let createdAt: Date

    // User information (denormalized for widget performance)
    let userName: String
    let userDisplayName: String
    let userProfileImageURL: String?

    // 事前ダウンロード済み画像のファイル名（App Group内 widgetImages/ 配下）
    // WidgetKitはスナップショット描画のためAsyncImageによるネットワーク取得が保証されない。
    // 本体アプリ側でダウンロードした画像をウィジェットが同期読み込みするために使用する。
    // Optionalのため、フィールドを持たない既存のwidgetData.jsonもデコード互換。
    let localImageFileName: String?
    let localProfileImageFileName: String?

    init(id: String,
         userId: String,
         imageURL: String,
         text: String,
         song: Song? = nil,
         createdAt: Date,
         userName: String,
         userDisplayName: String,
         userProfileImageURL: String? = nil,
         localImageFileName: String? = nil,
         localProfileImageFileName: String? = nil) {
        self.id = id
        self.userId = userId
        self.imageURL = imageURL
        self.text = text
        self.song = song
        self.createdAt = createdAt
        self.userName = userName
        self.userDisplayName = userDisplayName
        self.userProfileImageURL = userProfileImageURL
        self.localImageFileName = localImageFileName
        self.localProfileImageFileName = localProfileImageFileName
    }
}

// MARK: - Widget Data Model
struct WidgetData: Codable {
    let posts: [Post]
    let lastUpdated: Date

    init(posts: [Post], lastUpdated: Date = Date()) {
        self.posts = posts
        self.lastUpdated = lastUpdated
    }
}
