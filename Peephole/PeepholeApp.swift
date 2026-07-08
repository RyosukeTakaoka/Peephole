//
//  PeepholeApp.swift
//  Peephole
//
//  Main app entry point
//

import SwiftUI
import FirebaseCore
import FirebaseAppCheck

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        print("🔵 [APPDELEGATE] application didFinishLaunchingWithOptions")

        // App Checkのデバッグプロバイダを設定（開発環境用）
        // これにより、App Checkが未登録でもエラーが発生しなくなる
        #if DEBUG
        print("🔵 [APPDELEGATE] Setting up AppCheck debug provider...")
        let providerFactory = AppCheckDebugProviderFactory()
        AppCheck.setAppCheckProviderFactory(providerFactory)
        print("✅ [APPDELEGATE] AppCheck debug provider configured")
        #endif

        // デバッグ: GoogleService-Info.plistの読み込み確認
        if let filePath = Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist"),
           let plist = NSDictionary(contentsOfFile: filePath) {
            print("🔍 [DEBUG] GoogleService-Info.plist path: \(filePath)")
            print("🔍 [DEBUG] PROJECT_ID from loaded plist: \(plist["PROJECT_ID"] ?? "not found")")
            print("🔍 [DEBUG] BUNDLE_ID from loaded plist: \(plist["BUNDLE_ID"] ?? "not found")")
        } else {
            print("❌ [DEBUG] GoogleService-Info.plist NOT FOUND in bundle")
        }

        print("🔵 [APPDELEGATE] Configuring Firebase...")
        FirebaseApp.configure()
        print("✅ [APPDELEGATE] Firebase configured")
        return true
    }
}

@main
struct PeepholeApp: App {
    // Firebaseの初期化のためにAppDelegateを登録
    @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

    // 認証状態を管理するViewModel
    @StateObject private var authViewModel = AuthViewModel()

    init() {
        print("🔵 [APP] PeepholeApp init() started")
        // 【開発中】初回起動時のみモックデータを表示
        // 実際の投稿を作成すると、ウィジェットは実データに切り替わります
        setupMockDataIfNeeded()
        print("✅ [APP] PeepholeApp init() completed")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(authViewModel)
        }
    }

    private func setupMockDataIfNeeded() {
        // ウィジェットデータが存在しない場合のみ、初回起動時にモックデータを表示
        // 投稿を作成すると、実データで上書きされます
        if SharedDataManager.loadWidgetData() == nil {
            let mockData = SharedDataManager.generateMockData()
            SharedDataManager.saveWidgetData(mockData)
            print("📦 Mock data initialized for widget (will be replaced by real data after first post)")
        }
    }
}

// MARK: - Root View

struct RootView: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @Environment(\.scenePhase) var scenePhase

    var body: some View {
        Group {
            if authViewModel.isInitializing {
                // 初期化中: ローディング画面
                LoadingView()
            } else if authViewModel.isAuthenticated {
                // ログイン済み: メインアプリを表示
                MainTabView()
                    .environmentObject(authViewModel)
            } else {
                // 未ログイン: Welcome画面を表示
                WelcomeScreen()
                    .environmentObject(authViewModel)
            }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            // フォアグラウンドに戻った時にウィジェットを更新
            if newPhase == .active {
                updateWidgetIfNeeded()
            }
        }
        .onAppear {
            // アプリ起動時にウィジェットを更新
            updateWidgetIfNeeded()
        }
    }

    /// ログイン済みの場合のみウィジェットを更新
    private func updateWidgetIfNeeded() {
        guard let userId = authViewModel.currentUserId else {
            print("⚠️ [WIDGET] User not logged in, skipping widget update")
            return
        }

        Task {
            await WidgetDataUpdater.shared.updateWidgetWithFollowingPosts(userId: userId)
        }
    }
}

// MARK: - Loading View

struct LoadingView: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "eye.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)

                ProgressView()
                    .scaleEffect(1.2)

                Text("読み込み中...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}
