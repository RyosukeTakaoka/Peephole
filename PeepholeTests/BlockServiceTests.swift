//
//  BlockServiceTests.swift
//  PeepholeTests
//
//  BlockServiceのUnit Test
//  トランザクション処理の正確性を確認
//

import XCTest
@testable import Peephole
import FirebaseCore
import FirebaseFirestore

final class BlockServiceTests: XCTestCase {

    // MARK: - Properties
    var blockService: BlockService!
    var followService: FollowService!
    var userService: UserService!
    var db: Firestore!

    // テスト用のユーザーID
    let testUserA = "test_block_user_a_\(UUID().uuidString)"
    let testUserB = "test_block_user_b_\(UUID().uuidString)"

    // MARK: - Setup & Teardown
    override func setUpWithError() throws {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        blockService = BlockService.shared
        followService = FollowService.shared
        userService = UserService.shared
        db = Firestore.firestore()

        print("🧪 Test Setup: Creating test users...")
        print("   User A: \(testUserA)")
        print("   User B: \(testUserB)")

        let expectation = self.expectation(description: "Create test users")

        Task {
            do {
                try await userService.createUserProfile(
                    userId: testUserA,
                    username: "test_block_user_a",
                    displayName: "Test Block User A",
                    email: "test_block_a@example.com"
                )

                try await userService.createUserProfile(
                    userId: testUserB,
                    username: "test_block_user_b",
                    displayName: "Test Block User B",
                    email: "test_block_b@example.com"
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
                try await cleanupBlocks(userId: testUserA)
                try await cleanupBlocks(userId: testUserB)
                try await cleanupFollowRequests(userId: testUserA)
                try await cleanupFollowRequests(userId: testUserB)
                try await cleanupFollows(userId: testUserA)

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

    // MARK: - Test 1: ブロックの作成（複合IDとnotified）
    func testBlockUserCreatesDocumentWithCompositeId() throws {
        let expectation = self.expectation(description: "Block user")

        Task {
            do {
                try await blockService.blockUser(blockerId: testUserA, blockedId: testUserB)

                let expectedBlockId = "\(testUserA)_\(testUserB)"
                let doc = try await db.collection("blocks").document(expectedBlockId).getDocument()

                XCTAssertTrue(doc.exists, "複合IDのblocksドキュメントが作成されていること")

                let block = try doc.data(as: FirestoreBlock.self)
                XCTAssertEqual(block.blockerId, testUserA, "blockerIdが正しいこと")
                XCTAssertEqual(block.blockedId, testUserB, "blockedIdが正しいこと")
                XCTAssertFalse(block.notified, "notifiedがfalseで作成されること")

                print("✅ Test 1 Passed: Block created with composite id")
                expectation.fulfill()
            } catch {
                XCTFail("Test 1 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 2: フォロー関係・保留中リクエストの解消とカウント調整
    func testBlockUserRemovesFollowRelationshipAndAdjustsCounts() throws {
        let expectation = self.expectation(description: "Block removes follow relationship")

        Task {
            do {
                // 事前にA→Bのフォロー関係を確立
                try await followService.sendFollowRequest(from: testUserA, to: testUserB)
                let requests = try await followService.getPendingFollowRequests(targetId: testUserB)
                guard let request = requests.first else {
                    XCTFail("フォローリクエストが見つかりません")
                    expectation.fulfill()
                    return
                }
                try await followService.approveFollowRequest(requestId: request.requestId, currentUserId: testUserB)

                try await Task.sleep(nanoseconds: 1_000_000_000)

                let isFollowingBefore = try await followService.checkIfFollowing(followerId: testUserA, followingId: testUserB)
                XCTAssertTrue(isFollowingBefore, "ブロック前はフォロー関係が存在すること")

                let userABefore = try await userService.getUserProfile(userId: testUserA)
                let userBBefore = try await userService.getUserProfile(userId: testUserB)

                // ブロック実行
                try await blockService.blockUser(blockerId: testUserA, blockedId: testUserB)

                try await Task.sleep(nanoseconds: 1_000_000_000)

                let isFollowingAfter = try await followService.checkIfFollowing(followerId: testUserA, followingId: testUserB)
                XCTAssertFalse(isFollowingAfter, "ブロック後はフォロー関係が解消されていること")

                let userAAfter = try await userService.getUserProfile(userId: testUserA)
                let userBAfter = try await userService.getUserProfile(userId: testUserB)

                XCTAssertEqual(userAAfter.followingCount, userABefore.followingCount - 1, "AのfollowingCountが-1されていること")
                XCTAssertEqual(userBAfter.followersCount, userBBefore.followersCount - 1, "BのfollowersCountが-1されていること")

                print("✅ Test 2 Passed: Block removes follow relationship and adjusts counts")
                expectation.fulfill()
            } catch {
                XCTFail("Test 2 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 20)
    }

    // MARK: - Test 3: フォロー関係がないペアでもブロックがエラーにならない
    func testBlockUserWithoutExistingFollowDoesNotFail() throws {
        let expectation = self.expectation(description: "Block without existing follow")

        Task {
            do {
                try await blockService.blockUser(blockerId: testUserA, blockedId: testUserB)

                let blockedIds = try await blockService.getBlockedIds(userId: testUserA)
                XCTAssertTrue(blockedIds.contains(testUserB), "フォロー関係がなくてもブロックが成立すること")

                print("✅ Test 3 Passed: Block without existing follow does not fail")
                expectation.fulfill()
            } catch {
                XCTFail("Test 3 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Test 4: 二重ブロックの防止
    func testPreventDuplicateBlock() throws {
        let expectation = self.expectation(description: "Prevent duplicate block")

        Task {
            do {
                try await blockService.blockUser(blockerId: testUserA, blockedId: testUserB)

                do {
                    try await blockService.blockUser(blockerId: testUserA, blockedId: testUserB)
                    XCTFail("二重ブロックがエラーにならなかった")
                } catch BlockServiceError.alreadyBlocked {
                    print("✅ Test 4 Passed: Duplicate block prevented")
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

    // MARK: - Test 5: ブロック解除
    func testUnblockUserDeletesBlockDocument() throws {
        let expectation = self.expectation(description: "Unblock user")

        Task {
            do {
                try await blockService.blockUser(blockerId: testUserA, blockedId: testUserB)

                let blockedIdsBefore = try await blockService.getBlockedIds(userId: testUserA)
                XCTAssertTrue(blockedIdsBefore.contains(testUserB), "ブロック直後は一覧に含まれること")

                try await blockService.unblockUser(blockerId: testUserA, blockedId: testUserB)

                let blockedIdsAfter = try await blockService.getBlockedIds(userId: testUserA)
                XCTAssertFalse(blockedIdsAfter.contains(testUserB), "解除後は一覧から消えていること")

                let doc = try await db.collection("blocks").document("\(testUserA)_\(testUserB)").getDocument()
                XCTAssertFalse(doc.exists, "blocksドキュメントが削除されていること")

                print("✅ Test 5 Passed: Unblock deletes block document")
                expectation.fulfill()
            } catch {
                XCTFail("Test 5 Failed: \(error)")
                expectation.fulfill()
            }
        }

        waitForExpectations(timeout: 10)
    }

    // MARK: - Helper Methods
    private func cleanupBlocks(userId: String) async throws {
        let asBlocker = try await db.collection("blocks")
            .whereField("blockerId", isEqualTo: userId)
            .getDocuments()

        let asBlocked = try await db.collection("blocks")
            .whereField("blockedId", isEqualTo: userId)
            .getDocuments()

        for doc in asBlocker.documents {
            try await doc.reference.delete()
        }

        for doc in asBlocked.documents {
            try await doc.reference.delete()
        }
    }

    private func cleanupFollowRequests(userId: String) async throws {
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
