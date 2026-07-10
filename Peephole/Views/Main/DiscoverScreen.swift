//
//  DiscoverScreen.swift
//  Peephole
//
//  発見画面
//  ユーザー名検索とプロフィールへの遷移
//

import SwiftUI

struct DiscoverScreen: View {

    @StateObject private var viewModel = DiscoverViewModel()
    @EnvironmentObject var authViewModel: AuthViewModel

    var body: some View {
        ZStack {
            if viewModel.searchText.isEmpty {
                DiscoverGuideView()
            } else if viewModel.isSearching {
                ProgressView("検索中...")
            } else if viewModel.hasSearched && viewModel.results.isEmpty {
                DiscoverNoResultsView(query: viewModel.searchText)
            } else {
                List(viewModel.results) { user in
                    NavigationLink(value: user.userId) {
                        UserSearchRow(user: user)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("発見")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(
            text: $viewModel.searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "ユーザー名で検索"
        )
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .task(id: viewModel.searchText) {
            // デバウンス: 0.4秒待ってから検索。searchTextが変わるとこのtaskは
            // 自動キャンセル→再起動されるので、Task.sleepがそのままデバウンスになる
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let uid = authViewModel.currentUserId else { return }
            await viewModel.search(currentUserId: uid)
        }
        .navigationDestination(for: String.self) { userId in
            UserProfileScreen(targetUserId: userId)
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

// MARK: - Discover Guide View（未検索時の案内）

struct DiscoverGuideView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("@ユーザー名で友達を探そう")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - Discover No Results View

struct DiscoverNoResultsView: View {
    let query: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("「\(query)」に一致するユーザーが見つかりません")
                .font(.system(size: 16))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

// MARK: - User Search Row

struct UserSearchRow: View {
    let user: FirestoreUser

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: CloudinaryService.generateProfileImageURL(from: user.profileImageURL ?? "", size: 100))) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .resizable()
                    .foregroundColor(.gray)
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(.system(size: 15, weight: .semibold))

                Text("@\(user.username)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        DiscoverScreen()
            .environmentObject(AuthViewModel())
    }
}
