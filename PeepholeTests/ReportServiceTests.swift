//
//  ReportServiceTests.swift
//  PeepholeTests
//
//  ReportServiceのUnit Test
//  通報の作成とhiddenPostsの読み書きを確認
//

import XCTest
@testable import Peephole
import FirebaseCore
import FirebaseFirestore

final class ReportServiceTests: XCTestCase {

    // MARK: - Properties
    var reportService: ReportService!
    var userService: UserService!
    var db: Firestore!

    // テスト用のユーザーID
    let testReporter = "test_report_reporter_\(UUID().uuidString)"
    let testTargetUser = "test_report_target_\(UUID().uuidString)"

    // MARK: - Setup & Teardown
    override func setUpWithError() throws {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        reportService = ReportService.shared
        userService = UserService.shared
        db = Firestore.firestore()

        print("🧪 Test Setup: Creating test users...")

        let expectation = self.expectation(description: "Create test users")

        Task {
            do {
                try await userService.createUserProfile(
                    userId: testReporter,
                    username: "test_report_reporter",
                    displayName: "Test Reporter",
                    email: "test_reporter@example.com"
                )

                try await userService.createUserProfile(
                    userId: testTargetUser,
                    username: "test_report_target",
                    displayName: "Test Target",
                    email: "test_target@example.com"
                )

                print("✅ Test users created")
                expectation.fulfill()
            } catch {
                XCTFail("Failed to create test users: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    override func tearDownWithError() throws {
        print("🧹 Test Teardown: Cleaning up test data...")

        let expectation = self.expectation(description: "Cleanup test data")

        Task {
            do {
                // 注: reports はクライアントからの read/delete が禁止されているため、
                // このテストで作成した reports ドキュメントはクライアント側から
                // クリーンアップできない。Firebase コンソール / Admin SDK 側で
                // 定期的に削除するか、テスト用ドキュメントとして許容する。
                try await cleanupHiddenPosts(userId: testReporter)

                try await db.collection("users").document(testReporter).delete()
                try await db.collection("users").document(testTargetUser).delete()

                print("✅ Test data cleaned up")
                expectation.fulfill()
            } catch {
                print("⚠️ Cleanup error: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 1: 投稿の通報がスキーマ通りに作成される
    func testSubmitReportForPostCreatesDocumentWithPendingStatus() throws {
        let expectation = self.expectation(description: "Submit post report")

        Task {
            do {
                // 注: reports は §6.4 のルールでクライアントからの read が全面禁止
                // （allow read: if false）のため、作成後の read-back によるスキーマ検証は
                // 行わず、submitReport が例外を投げずに完了することのみを確認する。
                // スキーマの正確性は Firebase コンソール / Rules Playground で別途確認する。
                try await reportService.submitReport(
                    reporterId: testReporter,
                    targetType: .post,
                    targetPostId: "sample_post_id",
                    targetUserId: testTargetUser,
                    reason: .inappropriateContent,
                    detail: "テスト通報"
                )

                print("✅ Test 1 Passed: submitReport (post) completed without throwing")
                expectation.fulfill()
            } catch {
                XCTFail("Test 1 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 2: ユーザー通報の作成
    func testSubmitReportForUser() throws {
        let expectation = self.expectation(description: "Submit user report")

        Task {
            do {
                // 注: Test 1 と同様、reports の読み取り禁止のため read-back は行わない
                try await reportService.submitReport(
                    reporterId: testReporter,
                    targetType: .user,
                    targetPostId: nil,
                    targetUserId: testTargetUser,
                    reason: .harassment,
                    detail: nil
                )

                print("✅ Test 2 Passed: submitReport (user) completed without throwing")
                expectation.fulfill()
            } catch {
                XCTFail("Test 2 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 3: hidePost / getHiddenPostIds
    func testHidePostAndGetHiddenPostIds() throws {
        let expectation = self.expectation(description: "Hide post")

        Task {
            do {
                try await reportService.hidePost(userId: testReporter, postId: "hidden_post_1")

                let hiddenIds = try await reportService.getHiddenPostIds(userId: testReporter)

                XCTAssertTrue(hiddenIds.contains("hidden_post_1"), "非表示にした投稿IDが取得できること")

                print("✅ Test 3 Passed: hidePost and getHiddenPostIds")
                expectation.fulfill()
            } catch {
                XCTFail("Test 3 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Helper Methods
    private func cleanupHiddenPosts(userId: String) async throws {
        let querySnapshot = try await db.collection("users").document(userId)
            .collection("hiddenPosts")
            .getDocuments()

        for doc in querySnapshot.documents {
            try await doc.reference.delete()
        }
    }
}
