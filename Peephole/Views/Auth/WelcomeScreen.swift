//
//  WelcomeScreen.swift
//  Peephole
//
//  初回起動画面
//  ログイン/新規登録への導線を提供
//

import SwiftUI

struct WelcomeScreen: View {

    @EnvironmentObject var authViewModel: AuthViewModel
    @State private var showLogin = false
    @State private var showSignUp = false

    var body: some View {
        NavigationStack {
            ZStack {
                // 背景グラデーション
                LinearGradient(
                    colors: [Color.blue.opacity(0.6), Color.purple.opacity(0.6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 40) {
                    Spacer()

                    // ロゴ・タイトル
                    VStack(spacing: 16) {
                        Image(systemName: "eye.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.white)

                        Text("Peephole")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .foregroundColor(.white)

                        Text("友達の「今」を覗いてみよう")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }

                    Spacer()

                    // ボタン
                    VStack(spacing: 16) {
                        // ログインボタン
                        Button {
                            showLogin = true
                        } label: {
                            Text("ログイン")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.blue)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Color.white)
                                .cornerRadius(12)
                        }

                        // 新規登録ボタン
                        Button {
                            showSignUp = true
                        } label: {
                            Text("新規登録")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 54)
                                .background(Color.white.opacity(0.2))
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.white, lineWidth: 2)
                                )
                        }
                    }
                    .padding(.horizontal, 40)
                    .padding(.bottom, 50)
                }
            }
            .navigationDestination(isPresented: $showLogin) {
                LoginScreen()
                    .environmentObject(authViewModel)
            }
            .navigationDestination(isPresented: $showSignUp) {
                SignUpScreen()
                    .environmentObject(authViewModel)
            }
            .onAppear {
                print("✅ [WELCOME] WelcomeScreen appeared")
            }
        }
    }
}

#Preview {
    WelcomeScreen()
        .environmentObject(AuthViewModel())
}
