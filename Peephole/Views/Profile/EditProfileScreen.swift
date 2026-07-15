//
//  EditProfileScreen.swift
//  Peephole
//
//  プロフィール編集画面
//  表示名・自己紹介・プロフィール画像の編集
//

import SwiftUI
import PhotosUI

struct EditProfileScreen: View {

    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var bio: String = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedImage: UIImage?

    let maxBioLength = 150

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // プロフィール画像
                    PhotosPicker(
                        selection: $selectedPhotoItem,
                        matching: .images,
                        photoLibrary: .shared()
                    ) {
                        profileImageView
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            await loadSelectedImage(from: newItem)
                        }
                    }

                    // 表示名
                    VStack(alignment: .leading, spacing: 8) {
                        Text("表示名")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.secondary)

                        TextField("表示名を入力", text: $displayName)
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                    }

                    // 自己紹介
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("自己紹介")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)

                            Spacer()

                            Text("\(bio.count) / \(maxBioLength)")
                                .font(.system(size: 12))
                                .foregroundColor(bio.count > maxBioLength - 10 ? .red : .secondary)
                        }

                        TextEditor(text: $bio)
                            .frame(height: 100)
                            .padding(8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                            .onChange(of: bio) { _, _ in
                                if bio.count > maxBioLength {
                                    bio = String(bio.prefix(maxBioLength))
                                }
                            }
                    }
                }
                .padding(20)
            }
            .navigationTitle("プロフィールを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("キャンセル") {
                        dismiss()
                    }
                    .disabled(viewModel.isLoading)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        Task {
                            await save()
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(!hasChanges || viewModel.isLoading)
                }
            }
            .overlay {
                if viewModel.isLoading {
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
        }
        .interactiveDismissDisabled(viewModel.isLoading)
        .onAppear {
            displayName = viewModel.userProfile?.displayName ?? ""
            bio = viewModel.userProfile?.bio ?? ""
        }
    }

    // MARK: - Profile Image View

    private var profileImageView: some View {
        Group {
            if let selectedImage = selectedImage {
                Image(uiImage: selectedImage)
                    .resizable()
                    .scaledToFill()
            } else {
                AsyncImage(url: URL(string: viewModel.profileImageURL ?? "")) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundColor(.gray)
                }
            }
        }
        .frame(width: 100, height: 100)
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(Color.gray.opacity(0.2), lineWidth: 2)
        )
    }

    // MARK: - Change Detection

    private var hasChanges: Bool {
        let originalDisplayName = viewModel.userProfile?.displayName ?? ""
        let originalBio = viewModel.userProfile?.bio ?? ""
        return displayName != originalDisplayName || bio != originalBio || selectedImage != nil
    }

    // MARK: - Image Selection

    private func loadSelectedImage(from item: PhotosPickerItem?) async {
        guard let item = item else { return }

        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                self.selectedImage = uiImage
            }
        } catch {
            print("❌ Failed to load selected image: \(error)")
        }
    }

    // MARK: - Save

    private func save() async {
        viewModel.showError = false

        if let selectedImage = selectedImage {
            await viewModel.updateProfileImage(selectedImage)
        }

        let originalDisplayName = viewModel.userProfile?.displayName ?? ""
        let originalBio = viewModel.userProfile?.bio ?? ""
        if displayName != originalDisplayName || bio != originalBio {
            await viewModel.updateProfile(displayName: displayName, bio: bio)
        }

        if !viewModel.showError {
            dismiss()
        }
    }
}

#Preview {
    EditProfileScreen(viewModel: ProfileViewModel())
}
