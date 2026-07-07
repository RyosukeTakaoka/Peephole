//
//  PostCreateScreen.swift
//  Peephole
//
//  投稿作成画面
//  写真選択、テキスト入力、曲情報追加
//

import SwiftUI
import PhotosUI

struct PostCreateScreen: View {

    @StateObject private var viewModel = PostCreateViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedPhotoItem: PhotosPickerItem?
    @FocusState private var focusedField: Field?

    enum Field {
        case text, songTitle, songArtist
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                    // 写真選択
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        if let image = viewModel.selectedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity)
                                .frame(height: 300)
                                .cornerRadius(12)
                                .clipped()
                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "photo.on.rectangle.angled")
                                    .font(.system(size: 50))
                                    .foregroundColor(.blue)

                                Text("写真を選択")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundColor(.blue)
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 300)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(12)
                        }
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            await viewModel.selectImage(from: newItem)
                        }
                    }

                    // 投稿テキスト
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("一言メッセージ")
                                .font(.system(size: 16, weight: .medium))

                            Spacer()

                            Text("\(viewModel.postText.count) / \(viewModel.maxTextLength)")
                                .font(.system(size: 14))
                                .foregroundColor(viewModel.postText.count > viewModel.maxTextLength - 10 ? .red : .secondary)
                        }

                        TextEditor(text: $viewModel.postText)
                            .focused($focusedField, equals: .text)
                            .frame(height: 100)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .onChange(of: viewModel.postText) { _, _ in
                                viewModel.validateTextLength()
                            }
                    }

                    // 曲情報を追加
                    Toggle("🎵 曲情報を追加", isOn: $viewModel.includeSong)
                        .font(.system(size: 16, weight: .medium))

                    if viewModel.includeSong {
                        VStack(spacing: 12) {
                            // 曲名
                            VStack(alignment: .leading, spacing: 8) {
                                Text("曲名")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)

                                TextField("曲名を入力", text: $viewModel.songTitle)
                                    .focused($focusedField, equals: .songTitle)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                    .onChange(of: viewModel.songTitle) { _, _ in
                                        viewModel.validateSongTitleLength()
                                    }
                            }

                            // アーティスト名
                            VStack(alignment: .leading, spacing: 8) {
                                Text("アーティスト名")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundColor(.secondary)

                                TextField("アーティスト名を入力", text: $viewModel.songArtist)
                                    .focused($focusedField, equals: .songArtist)
                                    .padding()
                                    .background(Color(.systemGray6))
                                    .cornerRadius(8)
                                    .onChange(of: viewModel.songArtist) { _, _ in
                                        viewModel.validateArtistLength()
                                    }
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(12)
                    }

                    Spacer()
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)

            // アップロード進行状況
            if viewModel.isLoading {
                VStack {
                    Spacer()

                    VStack(spacing: 16) {
                        ProgressView(value: viewModel.uploadProgress)
                            .progressViewStyle(LinearProgressViewStyle())
                            .frame(width: 200)

                        Text(progressMessage)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(24)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(radius: 10)

                    Spacer()
                }
            }
        }
        .navigationTitle("投稿を作成")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("キャンセル") {
                    dismiss()
                }
                .disabled(viewModel.isLoading)
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button("投稿") {
                    focusedField = nil
                    Task {
                        if let userId = authViewModel.currentUserId {
                            await viewModel.createPost(currentUserId: userId)
                        }
                    }
                }
                .fontWeight(.semibold)
                .disabled(!viewModel.canPost || viewModel.isLoading)
            }
        }
        .alert("エラー", isPresented: $viewModel.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
            }
        }
        .onChange(of: viewModel.postCreated) { _, created in
            if created {
                // 投稿成功: モーダルを閉じる
                dismiss()
            }
        }
    }

    // MARK: - Progress Message

    private var progressMessage: String {
        if viewModel.uploadProgress < 0.4 {
            return "画像をアップロード中..."
        } else if viewModel.uploadProgress < 0.7 {
            return "ユーザー情報を取得中..."
        } else if viewModel.uploadProgress < 1.0 {
            return "投稿を作成中..."
        } else {
            return "完了！"
        }
    }
}

#Preview {
    NavigationStack {
        PostCreateScreen()
            .environmentObject(AuthViewModel())
    }
}
