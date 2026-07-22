//
//  NativeAdManager.swift
//  Peephole
//
//  ネイティブ広告（GoogleMobileAds v13）の「読み込み層」。
//  フィード表示時にすぐ差し込めるよう、広告を事前にまとめてロードして
//  在庫としてプールしておく。毎回同期ロードしないための仕組み。
//

import Foundation
import GoogleMobileAds

// MARK: - フィード表示用アイテム

/// フィードに並べる1要素を表す列挙型。
/// 投稿（post）と広告（ad）を同じ配列で扱えるようにすることで、
/// 既存の投稿モデル（FirestorePost）を汚さずに広告を混ぜ込める。
enum FeedItem: Identifiable {
    /// 通常の投稿
    case post(FirestorePost)
    /// ネイティブ広告（idは表示位置ベースの安定したキー、nativeAdはSDKの広告オブジェクト）
    case ad(id: String, nativeAd: NativeAd)

    /// SwiftUIのForEachが要素を識別するためのID
    var id: String {
        switch self {
        case .post(let post):
            return "post-\(post.postId)"
        case .ad(let id, _):
            return id
        }
    }
}

// MARK: - ネイティブ広告の事前ロード管理

/// ネイティブ広告をまとめて事前ロードし、在庫としてプールするマネージャ。
/// - `loadedAds` を @Published にしておき、広告が届いたらフィード側が再構築する。
/// - 広告の読み込みは非同期。ViewModel からは `preload()` を呼ぶだけでよい。
final class NativeAdManager: NSObject, ObservableObject {

    // MARK: - Published Properties

    /// 事前ロード済みのネイティブ広告の在庫
    @Published private(set) var loadedAds: [NativeAd] = []

    // MARK: - Private Properties

    /// GoogleMobileAds のローダー本体（loadを呼ぶと非同期で広告が届く）
    private var adLoader: AdLoader?

    /// 二重ロード防止フラグ
    private var isLoading = false

    // MARK: - Preload

    /// ネイティブ広告をまとめて事前ロードする。
    /// - Parameter count: 一度に取得する件数（デフォルトは AdConfig.preloadAdCount）
    func preload(count: Int = AdConfig.preloadAdCount) {
        // すでにロード中なら重複リクエストしない
        guard !isLoading else { return }
        isLoading = true

        // 複数件をまとめて取得するためのオプション（1リクエストで最大5件）
        let multipleAdsOptions = MultipleAdsAdLoaderOptions()
        multipleAdsOptions.numberOfAds = count

        // AdChoices（広告の情報アイコン）の表示位置を左上に固定する。
        // 自前の「広告」ラベルは右上に置くため、位置を分けて重なりを防ぐ。
        let viewOptions = NativeAdViewAdOptions()
        viewOptions.preferredAdChoicesPosition = .topLeftCorner

        let loader = AdLoader(
            adUnitID: AdConfig.nativeAdUnitID,
            rootViewController: Self.topViewController(),
            adTypes: [.native],
            options: [multipleAdsOptions, viewOptions]
        )
        loader.delegate = self
        self.adLoader = loader

        loader.load(Request())
        print("📢 [AD] ネイティブ広告のロード開始（\(count)件リクエスト）")
    }

    /// 在庫が少なくなってきたら追加でロードする。
    /// - Parameter remaining: 現在の未使用在庫数
    func preloadMoreIfNeeded(remaining: Int) {
        if remaining < 2 {
            preload()
        }
    }

    // MARK: - Helper

    /// 現在フォアグラウンドに表示中の rootViewController を取得する。
    /// ネイティブ広告のクリック時に遷移先を提示するために SDK が使用する。
    private static func topViewController() -> UIViewController? {
        let activeScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return activeScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    }
}

// MARK: - NativeAdLoaderDelegate

extension NativeAdManager: NativeAdLoaderDelegate {

    /// 広告が1件届くたびに呼ばれる（numberOfAds件ぶん呼ばれる）
    func adLoader(_ adLoader: AdLoader, didReceive nativeAd: NativeAd) {
        loadedAds.append(nativeAd)
        print("✅ [AD] ネイティブ広告を受信（在庫合計 \(loadedAds.count)件）")
    }

    /// ロードに失敗したときに呼ばれる
    func adLoader(_ adLoader: AdLoader, didFailToReceiveAdWithError error: Error) {
        isLoading = false
        print("❌ [AD] ネイティブ広告のロード失敗: \(error.localizedDescription)")
    }

    /// バッチ（複数件）のロードがすべて完了したときに呼ばれる
    func adLoaderDidFinishLoading(_ adLoader: AdLoader) {
        isLoading = false
        print("📢 [AD] ネイティブ広告のバッチロード完了（在庫合計 \(loadedAds.count)件）")
    }
}
