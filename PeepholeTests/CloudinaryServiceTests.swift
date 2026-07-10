//
//  CloudinaryServiceTests.swift
//  PeepholeTests
//
//  generateWidgetImageURL のロジックテスト（Firebase不要）
//

import Testing
@testable import Peephole

struct CloudinaryServiceTests {

    @Test func generateWidgetImageURL_insertsJPEGTransformation() async throws {
        let input = "https://res.cloudinary.com/demo/image/upload/v123/peephole/posts/abc.jpg"
        let result = CloudinaryService.generateWidgetImageURL(from: input, size: 400)
        #expect(result == "https://res.cloudinary.com/demo/image/upload/w_400,h_400,c_fill,q_auto,f_jpg/v123/peephole/posts/abc.jpg")
    }

    @Test func generateWidgetImageURL_supportsCustomSize() async throws {
        let input = "https://res.cloudinary.com/demo/image/upload/v123/peephole/profiles/abc.jpg"
        let result = CloudinaryService.generateWidgetImageURL(from: input, size: 150)
        #expect(result.contains("w_150,h_150,c_fill,q_auto,f_jpg"))
    }

    @Test func generateWidgetImageURL_nonCloudinaryURLReturnedUnchanged() async throws {
        let input = "https://picsum.photos/400/400?random=1"
        let result = CloudinaryService.generateWidgetImageURL(from: input, size: 400)
        #expect(result == input)
    }
}
