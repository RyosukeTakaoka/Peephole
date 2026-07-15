//
//  ModerationService.swift
//  Peephole
//
//  テキストのNGワードフィルタリングを担当
//  バンドル内のProhibitedWords.jsonを読み込み、投稿テキストやプロフィールの検証に使用する
//  将来的にはFirebase Remote Configで語彙を上書き取得できる構造に拡張できる
//

import Foundation

class ModerationService {

    // MARK: - Singleton
    static let shared = ModerationService()

    // MARK: - Private Properties

    private let prohibitedWords: [String]

    private init() {
        self.prohibitedWords = ModerationService.loadProhibitedWords()
        print("✅ [MODERATION] Loaded \(prohibitedWords.count) prohibited words")
    }

    // MARK: - Load Prohibited Words

    private static func loadProhibitedWords() -> [String] {
        guard let url = Bundle.main.url(forResource: "ProhibitedWords", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let words = try? JSONDecoder().decode([String].self, from: data) else {
            print("❌ [MODERATION] Failed to load ProhibitedWords.json")
            return []
        }
        return words
    }

    // MARK: - Contains Prohibited Word

    /// テキストにNGワードが含まれるかを判定する
    /// 大文字小文字を無視し、空白（改行・全角スペース含む）を除去したうえで部分一致を確認する
    /// - Parameter text: 判定対象のテキスト
    /// - Returns: NGワードが含まれていればtrue
    func containsProhibitedWord(_ text: String) -> Bool {
        let normalizedText = normalize(text)

        for word in prohibitedWords {
            let normalizedWord = normalize(word)
            guard !normalizedWord.isEmpty else { continue }

            if normalizedText.contains(normalizedWord) {
                return true
            }
        }

        return false
    }

    // MARK: - Normalize

    /// 大文字小文字と空白を正規化する
    private func normalize(_ text: String) -> String {
        return text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
    }
}
