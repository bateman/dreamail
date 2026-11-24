import Foundation

/// Google's OAuth2 userinfo response (`GET /oauth2/v2/userinfo`), the fields
/// the app reads. `picture` needs only the `userinfo.profile` scope the app
/// has always requested.
struct GoogleUserInfo: Decodable, Equatable {
    var email: String?
    var name: String?
    /// The account's own profile photo URL (lh3.googleusercontent.com).
    var picture: String?

    static func decode(_ data: Data) throws -> GoogleUserInfo {
        try JSONDecoder().decode(GoogleUserInfo.self, from: data)
    }
}
