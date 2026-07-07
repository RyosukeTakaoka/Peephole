//
//  FollowServiceTests.swift
//  PeepholeTests
//
//  FollowServiceのUnit Test
//  トランザクション処理の正確性を確認
//

import XCTest
@testable import Peephole
import FirebaseCore
import FirebaseFirestore

final class FollowServiceTests: XCTestCase {

    // MARK: - Properties
    var followService: FollowService!
    var userService: UserService!
    var db: Firestore!

    // テスト用のユーザーID
    let testUserA = "test_user_a_\(UUID().uuidString)"
    let testUserB = "test_user_b_\(UUID().uuidString)"

    // MARK: - Setup & Teardown
    override func setUpWithError() throws {
        // Firebase初期化（既に初期化済みの場合はスキップ）
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        followService = FollowService.shared
        userService = UserService.shared
        db = Firestore.firestore()

        print("🧪 Test Setup: Creating test users...")
        print("   User A: \(testUserA)")
        print("   User B: \(testUserB)")

        // テスト用のユーザーを作成（同期的に実行）
        let expectation = self.expectation(description: "Create test users")

        Task {
            do {
                // ユーザーAを作成
                try await userService.createUserProfile(
                    userId: testUserA,
                    username: "test_user_a",
                    displayName: "Test User A",
                    email: "test_a@example.com"
                )

                // ユーザーBを作成
                try await userService.createUserProfile(
                    userId: testUserB,
                    username: "test_user_b",
                    displayName: "Test User B",
                    email: "test_b@example.com"
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
                // テストユーザーのフォローリクエストを削除
                try await cleanupFollowRequests(userId: testUserA)
                try await cleanupFollowRequests(userId: testUserB)

                // テストユーザーのフォロー関係を削除
                try await cleanupFollows(userId: testUserA)

                // テストユーザーを削除
                try await db.collection("users").document(testUserA).delete()
                try await db.collection("users").document(testUserB).delete()

                print("✅ Test data cleaned up")
                expectation.fulfill()
            } catch {
                print("⚠️ Cleanup error: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 1: フォローリクエスト送信
    func testSendFollowRequest() throws {
        let expectation = self.expectation(description: "Send follow request")

        Task {
            do {
                // ユーザーAからユーザーBへフォローリクエストを送信
                try await followService.sendFollowRequest(
                    from: testUserA,
                    to: testUserB
                )

                // リクエストが作成されたか確認
                let requests = try await followService.getPendingFollowRequests(targetId: testUserB)

                XCTAssertEqual(requests.count, 1, "フォローリクエストが1件存在すること")
                XCTAssertEqual(requests.first?.requesterId, testUserA, "リクエスト送信者が正しいこと")
                XCTAssertEqual(requests.first?.targetId, testUserB, "リクエスト受信者が正しいこと")
                XCTAssertEqual(requests.first?.status, .pending, "ステータスがpendingであること")

                print("✅ Test 1 Passed: Follow request created successfully")
                expectation.fulfill()
            } catch {
                XCTFail("Test 1 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 2: フォローリクエスト承認（トランザクション）
    func testApproveFollowRequest() throws {
        let expectation = self.expectation(description: "Approve follow request")

        Task {
            do {
                // 1. フォローリクエストを送信
                try await followService.sendFollowRequest(
                    from: testUserA,
                    to: testUserB
                )

                // リクエストIDを取得
                let requests = try await followService.getPendingFollowRequests(targetId: testUserB)
                guard let request = requests.first else {
                    XCTFail("フォローリクエストが見つかりません")
                    expectation.fulfill()
                    return
                }
                let requestId = request.requestId

                // 承認前の統計情報を取得
                let userABefore = try await userService.getUserProfile(userId: testUserA)
                let userBBefore = try await userService.getUserProfile(userId: testUserB)

                print("📊 Before approval:")
                print("   User A followingCount: \(userABefore.followingCount)")
                print("   User B followersCount: \(userBBefore.followersCount)")

                // 2. フォローリクエストを承認（トランザクション）
                try await followService.approveFollowRequest(
                    requestId: requestId,
                    currentUserId: testUserB
                )

                // 少し待機（Firestoreの更新が反映されるまで）
                try await Task.sleep(nanoseconds: 1_000_000_000) // 1秒

                // 3. 検証: followsコレクションに関係が追加されたか
                let isFollowing = try await followService.checkIfFollowing(
                    followerId: testUserA,
                    followingId: testUserB
                )
                XCTAssertTrue(isFollowing, "フォロー関係が作成されていること")

                // 4. 検証: 統計情報が正しく更新されたか
                let userAAfter = try await userService.getUserProfile(userId: testUserA)
                let userBAfter = try await userService.getUserProfile(userId: testUserB)

                print("📊 After approval:")
                print("   User A followingCount: \(userAAfter.followingCount)")
                print("   User B followersCount: \(userBAfter.followersCount)")

                XCTAssertEqual(
                    userAAfter.followingCount,
                    userABefore.followingCount + 1,
                    "User AのfollowingCountが+1されていること"
                )
                XCTAssertEqual(
                    userBAfter.followersCount,
                    userBBefore.followersCount + 1,
                    "User BのfollowersCountが+1されていること"
                )

                // 5. 検証: フォローリクエストが削除されたか
                let requestsAfter = try await followService.getPendingFollowRequests(targetId: testUserB)
                XCTAssertEqual(requestsAfter.count, 0, "フォローリクエストが削除されていること")

                print("✅ Test 2 Passed: Follow request approved with transaction")
                expectation.fulfill()
            } catch {
                XCTFail("Test 2 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 15)
    }

    // MARK: - Test 3: フォロー解除（トランザクション）
    func testUnfollow() throws {
        let expectation = self.expectation(description: "Unfollow")

        Task {
            do {
                // 1. フォローリクエストを送信・承認（事前準備）
                try await followService.sendFollowRequest(from: testUserA, to: testUserB)
                let requests = try await followService.getPendingFollowRequests(targetId: testUserB)
                guard let request = requests.first else {
                    XCTFail("フォローリクエストが見つかりません")
                    expectation.fulfill()
                    return
                }
                try await followService.approveFollowRequest(
                    requestId: request.requestId,
                    currentUserId: testUserB
                )

                // 少し待機
                try await Task.sleep(nanoseconds: 1_000_000_000)

                // フォロー関係が存在することを確認
                let isFollowingBefore = try await followService.checkIfFollowing(
                    followerId: testUserA,
                    followingId: testUserB
                )
                XCTAssertTrue(isFollowingBefore, "フォロー関係が存在すること")

                // 統計情報を取得
                let userABefore = try await userService.getUserProfile(userId: testUserA)
                let userBBefore = try await userService.getUserProfile(userId: testUserB)

                print("📊 Before unfollow:")
                print("   User A followingCount: \(userABefore.followingCount)")
                print("   User B followersCount: \(userBBefore.followersCount)")

                // 2. フォロー解除（トランザクション）
                try await followService.unfollow(
                    followerId: testUserA,
                    followingId: testUserB
                )

                // 少し待機
                try await Task.sleep(nanoseconds: 1_000_000_000)

                // 3. 検証: フォロー関係が削除されたか
                let isFollowingAfter = try await followService.checkIfFollowing(
                    followerId: testUserA,
                    followingId: testUserB
                )
                XCTAssertFalse(isFollowingAfter, "フォロー関係が削除されていること")

                // 4. 検証: 統計情報が正しく更新されたか
                let userAAfter = try await userService.getUserProfile(userId: testUserA)
                let userBAfter = try await userService.getUserProfile(userId: testUserB)

                print("📊 After unfollow:")
                print("   User A followingCount: \(userAAfter.followingCount)")
                print("   User B followersCount: \(userBAfter.followersCount)")

                XCTAssertEqual(
                    userAAfter.followingCount,
                    userABefore.followingCount - 1,
                    "User AのfollowingCountが-1されていること"
                )
                XCTAssertEqual(
                    userBAfter.followersCount,
                    userBBefore.followersCount - 1,
                    "User BのfollowersCountが-1されていること"
                )

                print("✅ Test 3 Passed: Unfollow with transaction")
                expectation.fulfill()
            } catch {
                XCTFail("Test 3 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 20)
    }

    // MARK: - Test 4: 重複リクエストの防止
    func testPreventDuplicateRequest() throws {
        let expectation = self.expectation(description: "Prevent duplicate request")

        Task {
            do {
                // 1回目のリクエスト送信
                try await followService.sendFollowRequest(
                    from: testUserA,
                    to: testUserB
                )

                // 2回目のリクエスト送信（エラーになるべき）
                do {
                    try await followService.sendFollowRequest(
                        from: testUserA,
                        to: testUserB
                    )
                    XCTFail("重複リクエストがエラーにならなかった")
                } catch FollowServiceError.requestAlreadyExists {
                    // 正しいエラーが発生
                    print("✅ Test 4 Passed: Duplicate request prevented")
                } catch {
                    XCTFail("予期しないエラー: \(error)")
                }

                expectation.fulfill()
            } catch {
                XCTFail("Test 4 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 5: 自分自身をフォローできない
    func testCannotFollowSelf() throws {
        let expectation = self.expectation(description: "Cannot follow self")

        Task {
            do {
                // 自分自身へのフォローリクエスト（エラーになるべき）
                try await followService.sendFollowRequest(
                    from: testUserA,
                    to: testUserA
                )
                XCTFail("自分自身へのフォローがエラーにならなかった")
            } catch FollowServiceError.cannotFollowSelf {
                // 正しいエラーが発生
                print("✅ Test 5 Passed: Cannot follow self")
                expectation.fulfill()
            } catch {
                XCTFail("予期しないエラー: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 6: 既にフォロー中の場合
    func testCannotRequestIfAlreadyFollowing() throws {
        let expectation = self.expectation(description: "Cannot request if already following")

        Task {
            do {
                // フォロー関係を確立
                try await followService.sendFollowRequest(from: testUserA, to: testUserB)
                let requests = try await followService.getPendingFollowRequests(targetId: testUserB)
                guard let request = requests.first else {
                    XCTFail("フォローリクエストが見つかりません")
                    expectation.fulfill()
                    return
                }
                try await followService.approveFollowRequest(
                    requestId: request.requestId,
                    currentUserId: testUserB
                )

                // 少し待機
                try await Task.sleep(nanoseconds: 1_000_000_000)

                // 再度フォローリクエストを送信（エラーになるべき）
                do {
                    try await followService.sendFollowRequest(
                        from: testUserA,
                        to: testUserB
                    )
                    XCTFail("既にフォロー中なのにリクエストがエラーにならなかった")
                } catch FollowServiceError.alreadyFollowing {
                    // 正しいエラーが発生
                    print("✅ Test 6 Passed: Cannot request if already following")
                } catch {
                    XCTFail("予期しないエラー: \(error)")
                }

                expectation.fulfill()
            } catch {
                XCTFail("Test 6 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 15)
    }

    // MARK: - Helper Methods
    private func cleanupFollowRequests(userId: String) async throws {
        // userId が requester または target のリクエストを削除
        let requestsAsRequester = try await db.collection("followRequests")
            .whereField("requesterId", isEqualTo: userId)
            .getDocuments()

        let requestsAsTarget = try await db.collection("followRequests")
            .whereField("targetId", isEqualTo: userId)
            .getDocuments()

        for doc in requestsAsRequester.documents {
            try await doc.reference.delete()
        }

        for doc in requestsAsTarget.documents {
            try await doc.reference.delete()
        }
    }

    private func cleanupFollows(userId: String) async throws {
        // userId が follower または following のフォロー関係を削除
        let followsAsFollower = try await db.collection("follows")
            .whereField("followerId", isEqualTo: userId)
            .getDocuments()

        let followsAsFollowing = try await db.collection("follows")
            .whereField("followingId", isEqualTo: userId)
            .getDocuments()

        for doc in followsAsFollower.documents {
            try await doc.reference.delete()
        }

        for doc in followsAsFollowing.documents {
            try await doc.reference.delete()
        }
    }
}
