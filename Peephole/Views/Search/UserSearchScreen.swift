//
//  UserSearchScreen.swift
//  Peephole
//
//  ユーザー検索画面
//  ユーザー名で検索し、UserProfileScreenへの導線を提供
//

import SwiftUI

struct UserSearchScreen: View {

    @StateObject private var viewModel = UserSearchViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel

    var body: some View {
        ZStack {
            if viewModel.isLoading {
                ProgressView("検索中...")
            } else if viewModel.isEmptyResult {
                UserSearchStateView(
                    systemImage: "person.crop.circle.badge.questionmark",
                    message: "ユーザーが見つかりませんでした"
                )
            } else if viewModel.hasSearched {
                List {
                    ForEach(viewModel.results) { user in
                        NavigationLink {
                            UserProfileScreen(targetUserId: user.userId)
                        } label: {
                            UserSearchResultRow(user: user)
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                UserSearchStateView(
                    systemImage: "magnifyingglass",
                    message: "ユーザー名で検索できます"
                )
            }
        }
        .navigationTitle("ユーザーを検索")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.query, prompt: "ユーザー名で検索")
        .onSubmit(of: .search) {
            Task {
                if let userId = authViewModel.currentUserId {
                    await viewModel.search(query: viewModel.query, currentUserId: userId)
                }
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
}

// MARK: - User Search Result Row

struct UserSearchResultRow: View {

    let user: FirestoreUser

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: user.profileImageURL ?? "")) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundColor(.gray)
            }
            .frame(width: 50, height: 50)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(user.displayName)
                    .font(.system(size: 16, weight: .semibold))

                Text("@\(user.username)")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - User Search State View

/// 検索前の案内表示・0件の空状態を表示する共通ビュー
struct UserSearchStateView: View {

    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: systemImage)
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text(message)
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

#Preview {
    NavigationStack {
        UserSearchScreen()
            .environmentObject(AuthViewModel())
    }
}
