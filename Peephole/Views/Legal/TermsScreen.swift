//
//  TermsScreen.swift
//  Peephole
//
//  利用規約・プライバシーポリシーの全文を表示する画面（表示専用）
//

import SwiftUI

enum LegalDocumentType {
    case terms
    case privacyPolicy

    var title: String {
        switch self {
        case .terms:
            return "利用規約"
        case .privacyPolicy:
            return "プライバシーポリシー"
        }
    }

    var body: String {
        switch self {
        case .terms:
            return LegalTexts.termsOfService
        case .privacyPolicy:
            return LegalTexts.privacyPolicy
        }
    }
}

struct TermsScreen: View {

    let documentType: LegalDocumentType

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(documentType.body)
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .navigationTitle(documentType.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("閉じる") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    TermsScreen(documentType: .terms)
}
