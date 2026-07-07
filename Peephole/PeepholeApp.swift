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
        // Initialize mock data for widget on first launch
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
        // Check if widget data already exists
        if SharedDataManager.loadWidgetData() == nil {
            // Generate and save mock data
            let mockData = SharedDataManager.generateMockData()
            SharedDataManager.saveWidgetData(mockData)
            print("📦 Mock data initialized for widget")
        }
    }
}

// MARK: - Root View

struct RootView: View {

    @EnvironmentObject var authViewModel: AuthViewModel

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
