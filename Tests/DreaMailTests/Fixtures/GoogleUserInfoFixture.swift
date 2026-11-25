import Foundation

/// The shape of Google's `GET https://www.googleapis.com/oauth2/v2/userinfo`
/// response with the `userinfo.email` + `userinfo.profile` scopes. Values
/// are synthetic; the photo path is not a real account's.
enum GoogleUserInfoFixture {
    static let withPhoto = """
        {
          "id": "100000000000000000001",
          "email": "ada@example.com",
          "verified_email": true,
          "name": "Ada Lovelace",
          "given_name": "Ada",
          "family_name": "Lovelace",
          "picture": "https://lh3.googleusercontent.com/a/ACg8ocLsynthetic0000000000000000000000000000000000=s96-c",
          "locale": "en"
        }
        """

    /// Workspace account (`hd`) without a picture field.
    static let withoutPhoto = """
        {
          "id": "100000000000000000002",
          "email": "bob@example.org",
          "verified_email": true,
          "name": "Bob",
          "hd": "example.org"
        }
        """

    /// Legacy default silhouette URL.
    static let legacySilhouette = """
        {
          "id": "100000000000000000003",
          "email": "cy@example.com",
          "verified_email": true,
          "picture": "https://lh3.googleusercontent.com/-XdUIqdMkCWA/AAAAAAAAAAI/AAAAAAAAAAA/4252rscbv5M/photo.jpg"
        }
        """
}
