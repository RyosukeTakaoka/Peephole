//
//  TermsAgreementScreen.swift
//  Peephole
//
//  既存ユーザー向けの再同意画面
//  規約が改定された場合など、同意するまで閉じることができない
//

import SwiftUI

struct TermsAgreementScreen: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var isAgreeing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("利用規約とプライバシーポリシーが更新されました。引き続きご利用いただくには、内容をご確認のうえ同意してください。")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)

                        Text(LegalTexts.termsOfService)
                            .font(.system(size: 14))

                        Divider()

                        Text(LegalTexts.privacyPolicy)
                            .font(.system(size: 14))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }

                Button {
                    Task {
                        isAgreeing = true
                        await authViewModel.agreeToCurrentTerms()
                        isAgreeing = false
                    }
                } label: {
                    if isAgreeing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    } else {
                        Text("同意する")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                    }
                }
                .background(Color.blue)
                .cornerRadius(12)
                .disabled(isAgreeing)
                .padding(20)
            }
            .navigationTitle("利用規約の更新")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(true)
        .alert("エラー", isPresented: $authViewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = authViewModel.errorMessage {
                Text(errorMessage)
            }
        }
    }
}

#Preview {
    TermsAgreementScreen()
        .environmentObject(AuthViewModel())
}
