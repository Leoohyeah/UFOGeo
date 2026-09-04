import Foundation
import Testing
@testable import UFOGeo

struct FirebaseAuthServiceTests {
    @Test func refreshTokenFormEncodingEscapesReservedCharacters() throws {
        let data = FirebaseAuthService.formEncodedBody([
            "grant_type": "refresh_token",
            "refresh_token": "token+with&reserved=value/%"
        ])
        let body = try #require(String(data: data, encoding: .utf8))

        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("refresh_token=token%2Bwith%26reserved%3Dvalue%2F%25"))
        #expect(body.split(separator: "&").count == 2)
    }
}