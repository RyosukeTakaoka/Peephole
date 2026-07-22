//
//  NativeAdCardView.swift
//  Peephole
//
//  ネイティブ広告の「表示層」。
//  GoogleMobileAds の UIKit 製 NativeAdView を UIViewRepresentable で
//  SwiftUI にブリッジし、既存の投稿セル（PostCardView）に馴染む見た目にする。
//
//  ポリシー遵守のため、必ず以下を満たす:
//   - 「広告」ラベルを常時・明確に表示（セル上部）
//   - AdChoices アイコンを表示（SDKが自動描画。位置は左上に設定済み）
//   - すべてのアセットを SDK の NativeAdView 配下に登録
//   - Call to Action はクリック可能領域として SDK に登録
//

import SwiftUI
import GoogleMobileAds

// MARK: - SwiftUI 側のカード（背景・角丸・影などのカード装飾を担当）

/// フィードに差し込むネイティブ広告カード。
/// 投稿セル（PostCardView）と同じカード装飾を施し、フィードに自然に溶け込ませる。
struct NativeAdCardView: View {

    let nativeAd: NativeAd

    var body: some View {
        NativeAdViewRepresentable(nativeAd: nativeAd)
            .padding(16)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 5, x: 0, y: 2)
            .padding(.horizontal, 16)
    }
}

// MARK: - UIKit の NativeAdView を SwiftUI にブリッジ

/// GoogleMobileAds の NativeAdView を SwiftUI で使えるようにするラッパー。
/// 広告アセット（見出し・アイコン・メディア・本文・広告主・CTA）を
/// SDK指定のビュー階層に登録し、規約に沿った形で表示する。
struct NativeAdViewRepresentable: UIViewRepresentable {

    let nativeAd: NativeAd

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NativeAdView {
        let adView = NativeAdView()
        context.coordinator.buildLayout(in: adView)
        return adView
    }

    func updateUIView(_ uiView: NativeAdView, context: Context) {
        context.coordinator.configure(uiView, with: nativeAd)
    }

    /// SwiftUI にセルの高さを正しく伝えるための自己サイズ計算。
    /// 本文の行数などで高さが変わっても崩れないよう、Auto Layout に高さを求める。
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeAdView, context: Context) -> CGSize? {
        let width = proposal.width ?? (UIScreen.main.bounds.width - 64)
        let fittingSize = uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        return CGSize(width: width, height: fittingSize.height)
    }

    // MARK: - Coordinator（UIKitビューの生成と広告アセットの紐付けを担当）

    final class Coordinator {

        // 各アセットを表示するためのビュー（一度作って使い回す）
        private let iconImageView = UIImageView()
        private let headlineLabel = UILabel()
        private let advertiserLabel = UILabel()
        private let sponsoredBadge = PaddingLabel()
        private let mediaContainer = UIView()
        private let mediaView = MediaView()
        private let fallbackImageView = UIImageView()
        private let bodyLabel = UILabel()
        private let ctaButton = UIButton(type: .system)

        // MARK: - レイアウト構築（初回のみ）

        /// NativeAdView の中に、投稿セルと似た構図でサブビューを組み立てる。
        func buildLayout(in adView: NativeAdView) {

            // --- アイコン（アバター相当）---
            iconImageView.contentMode = .scaleAspectFill
            iconImageView.clipsToBounds = true
            iconImageView.layer.cornerRadius = 20
            iconImageView.backgroundColor = UIColor.systemGray5
            iconImageView.translatesAutoresizingMaskIntoConstraints = false
            iconImageView.widthAnchor.constraint(equalToConstant: 40).isActive = true
            iconImageView.heightAnchor.constraint(equalToConstant: 40).isActive = true
            iconImageView.setContentHuggingPriority(.required, for: .horizontal)

            // --- 見出し（ユーザー名相当）---
            headlineLabel.font = .systemFont(ofSize: 16, weight: .semibold)
            headlineLabel.textColor = .label
            headlineLabel.numberOfLines = 1

            // --- 広告主（@ユーザー名相当）---
            advertiserLabel.font = .systemFont(ofSize: 14)
            advertiserLabel.textColor = .secondaryLabel
            advertiserLabel.numberOfLines = 1

            // 見出し + 広告主を縦に並べる
            let textStack = UIStackView(arrangedSubviews: [headlineLabel, advertiserLabel])
            textStack.axis = .vertical
            textStack.spacing = 2

            // --- 「広告」識別ラベル（常時表示・一目で分かる位置＝右上）---
            sponsoredBadge.text = "広告"
            sponsoredBadge.font = .systemFont(ofSize: 12, weight: .semibold)
            sponsoredBadge.textColor = .secondaryLabel
            sponsoredBadge.backgroundColor = UIColor.systemGray5
            sponsoredBadge.layer.cornerRadius = 4
            sponsoredBadge.clipsToBounds = true
            sponsoredBadge.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
            sponsoredBadge.setContentHuggingPriority(.required, for: .horizontal)

            // ヘッダー行（アイコン・テキスト・広告ラベル）
            let headerRow = UIStackView(arrangedSubviews: [iconImageView, textStack, sponsoredBadge])
            headerRow.axis = .horizontal
            headerRow.spacing = 12
            headerRow.alignment = .center

            // --- メディア（投稿画像相当）。画像も動画もここに表示 ---
            mediaView.translatesAutoresizingMaskIntoConstraints = false
            fallbackImageView.contentMode = .scaleAspectFill
            fallbackImageView.clipsToBounds = true
            fallbackImageView.translatesAutoresizingMaskIntoConstraints = false

            mediaContainer.clipsToBounds = true
            mediaContainer.layer.cornerRadius = 12
            mediaContainer.backgroundColor = UIColor.systemGray6
            mediaContainer.translatesAutoresizingMaskIntoConstraints = false
            mediaContainer.addSubview(fallbackImageView)
            mediaContainer.addSubview(mediaView)
            // メディア枠は投稿画像と同じ高さ（300pt）
            mediaContainer.heightAnchor.constraint(equalToConstant: 300).isActive = true
            NSLayoutConstraint.activate([
                fallbackImageView.topAnchor.constraint(equalTo: mediaContainer.topAnchor),
                fallbackImageView.bottomAnchor.constraint(equalTo: mediaContainer.bottomAnchor),
                fallbackImageView.leadingAnchor.constraint(equalTo: mediaContainer.leadingAnchor),
                fallbackImageView.trailingAnchor.constraint(equalTo: mediaContainer.trailingAnchor),
                mediaView.topAnchor.constraint(equalTo: mediaContainer.topAnchor),
                mediaView.bottomAnchor.constraint(equalTo: mediaContainer.bottomAnchor),
                mediaView.leadingAnchor.constraint(equalTo: mediaContainer.leadingAnchor),
                mediaView.trailingAnchor.constraint(equalTo: mediaContainer.trailingAnchor),
            ])

            // --- 本文（投稿テキスト相当）---
            bodyLabel.font = .systemFont(ofSize: 16)
            bodyLabel.textColor = .label
            bodyLabel.numberOfLines = 3

            // --- Call to Action ボタン（「詳細」など）---
            // iOS 15以降で推奨の UIButton.Configuration を使う（旧 contentEdgeInsets は非推奨）
            var ctaConfig = UIButton.Configuration.filled()
            ctaConfig.baseBackgroundColor = .systemBlue
            ctaConfig.baseForegroundColor = .white
            ctaConfig.background.cornerRadius = 8
            ctaConfig.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16)
            ctaConfig.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 15, weight: .semibold)
                return outgoing
            }
            ctaButton.configuration = ctaConfig
            // クリックは SDK に任せるため、ボタン自身のタップ処理は無効化する
            ctaButton.isUserInteractionEnabled = false

            // --- 全体を縦に積む ---
            let mainStack = UIStackView(arrangedSubviews: [headerRow, mediaContainer, bodyLabel, ctaButton])
            mainStack.axis = .vertical
            mainStack.spacing = 12
            mainStack.alignment = .fill
            mainStack.translatesAutoresizingMaskIntoConstraints = false

            adView.addSubview(mainStack)
            NSLayoutConstraint.activate([
                mainStack.topAnchor.constraint(equalTo: adView.topAnchor),
                mainStack.bottomAnchor.constraint(equalTo: adView.bottomAnchor),
                mainStack.leadingAnchor.constraint(equalTo: adView.leadingAnchor),
                mainStack.trailingAnchor.constraint(equalTo: adView.trailingAnchor),
            ])

            // --- SDK のアセット用アウトレットに登録（規約上、必須）---
            adView.headlineView = headlineLabel
            adView.advertiserView = advertiserLabel
            adView.iconView = iconImageView
            adView.bodyView = bodyLabel
            adView.mediaView = mediaView
            adView.callToActionView = ctaButton
        }

        // MARK: - 広告内容の反映（広告が変わるたびに呼ばれる）

        /// 受け取った NativeAd の各アセットをビューに流し込み、最後に SDK へ登録する。
        func configure(_ adView: NativeAdView, with nativeAd: NativeAd) {

            // 見出し
            headlineLabel.text = nativeAd.headline

            // 広告主（無ければ store で代替、それも無ければ非表示）
            let advertiserText = nativeAd.advertiser ?? nativeAd.store
            advertiserLabel.text = advertiserText
            advertiserLabel.isHidden = (advertiserText == nil)

            // アイコン（無ければ非表示にして詰める）
            if let iconImage = nativeAd.icon?.image {
                iconImageView.image = iconImage
                iconImageView.isHidden = false
            } else {
                iconImageView.isHidden = true
            }

            // 本文（無ければ非表示）
            bodyLabel.text = nativeAd.body
            bodyLabel.isHidden = (nativeAd.body?.isEmpty ?? true)

            // メディア（画像/動画）。無ければフォールバックし、それも無ければ枠自体を非表示。
            // aspectRatio > 0 は「表示すべきメディアが存在する」ことを表し、
            // 画像広告・動画広告のどちらも MediaView がそのまま描画してくれる。
            mediaContainer.isHidden = false
            let media = nativeAd.mediaContent
            if media.hasVideoContent || media.aspectRatio > 0 {
                mediaView.mediaContent = media
                mediaView.isHidden = false
                fallbackImageView.isHidden = true
            } else if let firstImage = nativeAd.images?.first?.image {
                fallbackImageView.image = firstImage
                fallbackImageView.isHidden = false
                mediaView.isHidden = true
            } else {
                // メディアが全く無い広告 → メディア枠ごと非表示にして崩れを防ぐ
                mediaContainer.isHidden = true
            }

            // Call to Action（無ければ非表示）
            if let cta = nativeAd.callToAction {
                ctaButton.configuration?.title = cta
                ctaButton.isHidden = false
            } else {
                ctaButton.isHidden = true
            }

            // 最後に nativeAd を登録して、全アセットの紐付けとクリック計測を有効化する
            adView.nativeAd = nativeAd
        }
    }
}

// MARK: - 内側に余白を持てる UILabel（「広告」バッジ用）

/// テキストの周囲に余白（インセット）を付けられる UILabel。
/// 「広告」バッジをカプセル状に見せるために使う。
final class PaddingLabel: UILabel {

    var textInsets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: textInsets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}
