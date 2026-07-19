//
//  ReportScreen.swift
//  Peephole
//
//  通報画面（sheet表示）
//  理由選択と任意の詳細入力を行い、通報を送信する
//

import SwiftUI

struct ReportScreen: View {

    let reporterId: String
    let targetType: ReportTargetType
    let targetPostId: String?
    let targetUserId: String

    /// 送信完了時に呼ばれるコールバック（投稿通報時のローカル即時反映などに使用）
    var onReported: (() -> Void)?

    @StateObject private var viewModel = ReportViewModel()
    @Environment(\.dismiss) private var dismiss

    @State private var showCompletionAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section("理由を選択してください") {
                    ForEach(ReportReason.allCases, id: \.self) { reason in
                        Button {
                            viewModel.selectedReason = reason
                        } label: {
                            HStack {
                                Text(reason.displayName)
                                    .foregroundColor(.primary)

                                Spacer()

                                if viewModel.selectedReason == reason {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                    }
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("詳細（任意）")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("\(viewModel.detail.count) / \(viewModel.maxDetailLength)")
                                .font(.system(size: 12))
                                .foregroundColor(viewModel.detail.count > viewModel.maxDetailLength - 20 ? .red : .secondary)
                        }

                        TextEditor(text: $viewModel.detail)
                            .frame(height: 100)
                            .onChange(of: viewModel.detail) { _, _ in
                                viewModel.validateDetailLength()
                            }
                    }
                } header: {
                    Text("詳細")
                }
            }
            .navigationTitle("通報")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .disabled(viewModel.isSubmitting)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("送信") {
                        Task {
                            await viewModel.submitReport(
                                reporterId: reporterId,
                                targetType: targetType,
                                targetPostId: targetPostId,
                                targetUserId: targetUserId
                            )
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!viewModel.canSubmit)
                }
            }
            .overlay {
                if viewModel.isSubmitting {
                    ProgressView()
                        .padding(24)
                        .background(Color(.systemBackground))
                        .cornerRadius(12)
                        .shadow(radius: 10)
                }
            }
            .alert("エラー", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let errorMessage = viewModel.errorMessage {
                    Text(errorMessage)
                }
            }
            .alert("通報を受け付けました。24時間以内に対応します", isPresented: $showCompletionAlert) {
                Button("OK") {
                    onReported?()
                    dismiss()
                }
            }
            .onChange(of: viewModel.reportSubmitted) { _, submitted in
                if submitted {
                    showCompletionAlert = true
                }
            }
        }
    }
}

#Preview {
    ReportScreen(
        reporterId: "sample_reporter_id",
        targetType: .post,
        targetPostId: "sample_post_id",
        targetUserId: "sample_target_user_id"
    )
}
