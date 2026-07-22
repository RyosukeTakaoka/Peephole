//
//  AdConfig.swift
//  Peephole
//
//  AdMob（Google Mobile Ads）関連の設定を一元管理する定数ファイル
//  広告ユニットIDやフィードへの差し込み頻度など、
//  「広告に関する数字・ID」はすべてここに集約する。
//  → 本番IDへの差し替えや頻度変更を1箇所で行えるようにするため。
//

import Foundation

/// AdMob 広告設定の定数
enum AdConfig {

    // MARK: - ネイティブ広告ユニットID

    /// フィードに差し込むネイティブ広告のユニットID
    ///
    /// DEBUG（開発）ビルドでは Google 公式のテスト用IDを使用し、
    /// リリースビルドでは本番IDを使用する。
    /// テストIDを使うことで、審査前でも安全に広告表示の動作確認ができる。
    #if DEBUG
    /// Google公式のネイティブ広告テストID（開発時は必ずこれを使う）
    static let nativeAdUnitID = "ca-app-pub-3940256099942544/3986624511"
    #else
    /// 【要差し替え】本番のネイティブ広告ユニットIDを入れる。
    /// AdMob 管理画面でネイティブ広告ユニットを作成し、発行された
    /// "ca-app-pub-1406324564337535/XXXXXXXXXX" 形式のIDに置き換えること。
    static let nativeAdUnitID = "ca-app-pub-1406324564337535/XXXXXXXXXX"
    #endif

    // MARK: - フィードへの差し込み設定

    /// 投稿を何件表示するごとに広告を1件挟むか（例: 5 なら 投稿5件 → 広告1件）
    /// あとから頻度を変えられるよう定数化している。
    static let feedAdInterval = 5

    /// 一度に事前ロードするネイティブ広告の件数
    /// （Google の仕様上、1リクエストあたり最大5件までまとめて取得できる）
    static let preloadAdCount = 5
}
