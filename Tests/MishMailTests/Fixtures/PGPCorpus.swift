import Foundation

/// Hand-written OpenPGP test messages (step 4B). TEST MATERIAL ONLY.
///
/// The MIME structures are realistic (the shapes Thunderbird, GnuPG-based
/// clients, mailing lists and Proton produce), but every armored block holds
/// the base64 of a plain-English marker, never OpenPGP packets: nothing here
/// is a key, a signature or a ciphertext, and there is no private-key block
/// anywhere. Domains are reserved (`example.org`, `example.net`).
///
/// Literals use LF; `crlf(_:)` gives the wire form. Both forms must give the
/// same signed bytes.
enum PGPCorpus {
    /// base64("TEST ONLY - NOT OPENPGP DATA - MISHMAIL FIXTURE")
    static let fakePayload = "VEVTVCBPTkxZIC0gTk9UIE9QRU5QR1AgREFUQSAtIE1JU0hNQUlMIEZJWFRVUkU="
    /// base64("TEST ONLY - NOT AN OPENPGP KEY - MISHMAIL FIXTURE")
    static let fakeKeyPayload = "VEVTVCBPTkxZIC0gTk9UIEFOIE9QRU5QR1AgS0VZIC0gTUlTSE1BSUwgRklYVFVSRQ=="

    static let fakeSignature = """
        -----BEGIN PGP SIGNATURE-----

        \(fakePayload)
        =TEST
        -----END PGP SIGNATURE-----
        """

    static let fakeMessage = """
        -----BEGIN PGP MESSAGE-----

        \(fakePayload)
        =TEST
        -----END PGP MESSAGE-----
        """

    static let fakePublicKey = """
        -----BEGIN PGP PUBLIC KEY BLOCK-----

        \(fakeKeyPayload)
        =TEST
        -----END PGP PUBLIC KEY BLOCK-----
        """

    static func crlf(_ s: String) -> Data {
        Data(s.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    static func lf(_ s: String) -> Data { Data(s.utf8) }

    // MARK: - multipart/signed at the root

    /// The signed part's exact bytes, in canonical form: from after the
    /// first delimiter line to before the line break preceding the second.
    static let signedPartCanonical = Data((
        "Content-Type: text/plain; charset=utf-8\r\n" +
        "Content-Transfer-Encoding: quoted-printable\r\n" +
        "\r\n" +
        "Hello Bob,\r\n" +
        "this text is signed.=20\r\n" +
        "\r\n" +
        "-- \r\n" +
        "Alice").utf8)

    /// `delimiterSuffix` goes after `--sig-boundary` on the delimiter line
    /// before the signature part (RFC 2046 transport padding).
    static func signedSimple(delimiterSuffix: String = "") -> String {
        """
        From: Alice Example <alice@example.org>
        To: Bob Example <bob@example.net>
        Subject: Signed test message
        Message-ID: <signed-simple@example.org>
        MIME-Version: 1.0
        Content-Type: multipart/signed; micalg=pgp-sha256;
         protocol="application/pgp-signature";
         boundary="sig-boundary"

        This is an OpenPGP/MIME signed message (RFC 4880 and 3156)
        --sig-boundary
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Hello Bob,
        this text is signed.=20

        --\u{20}
        Alice
        --sig-boundary\(delimiterSuffix)
        Content-Type: application/pgp-signature; name="signature.asc"
        Content-Description: OpenPGP digital signature
        Content-Disposition: attachment; filename="signature.asc"

        \(fakeSignature)
        --sig-boundary--

        Epilogue text that no signature covers.
        """
    }

    /// The signed part is itself multipart/mixed with an attachment, and its
    /// text contains a line that starts like the outer boundary but is not
    /// a delimiter.
    static let signedNested = """
        From: Alice Example <alice@example.org>
        To: Bob Example <bob@example.net>
        Subject: Signed with attachment
        MIME-Version: 1.0
        Content-Type: multipart/signed; boundary=outer; protocol="application/pgp-signature"; micalg="PGP-SHA512"

        --outer
        Content-Type: multipart/mixed; boundary="inner"

        --inner
        Content-Type: text/plain; charset=us-ascii

        See attached.
        --outerX is not a delimiter, nor is --outer-- inside a word: x--outer
        --inner
        Content-Type: application/octet-stream; name="notes.txt"
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment; filename="notes.txt"

        VEVTVCBPTkxZ
        --inner--
        --outer
        Content-Type: application/pgp-signature

        \(fakeSignature)
        --outer--
        """

    static let signedNestedPartCanonical = Data((
        "Content-Type: multipart/mixed; boundary=\"inner\"\r\n" +
        "\r\n" +
        "--inner\r\n" +
        "Content-Type: text/plain; charset=us-ascii\r\n" +
        "\r\n" +
        "See attached.\r\n" +
        "--outerX is not a delimiter, nor is --outer-- inside a word: x--outer\r\n" +
        "--inner\r\n" +
        "Content-Type: application/octet-stream; name=\"notes.txt\"\r\n" +
        "Content-Transfer-Encoding: base64\r\n" +
        "Content-Disposition: attachment; filename=\"notes.txt\"\r\n" +
        "\r\n" +
        "VEVTVCBPTkxZ\r\n" +
        "--inner--").utf8)

    /// A mailing list appended a footer by wrapping the signed message in
    /// multipart/mixed: the signature covers only the first part.
    static let listWrapped = """
        From: Alice Example <alice@example.org>
        To: list@example.net
        Subject: [list] Signed post
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="list-wrap"

        --list-wrap
        Content-Type: multipart/signed; micalg=pgp-sha256;
         protocol="application/pgp-signature"; boundary="sig-boundary"

        --sig-boundary
        Content-Type: text/plain; charset=utf-8

        The signed post.
        --sig-boundary
        Content-Type: application/pgp-signature

        \(fakeSignature)
        --sig-boundary--
        --list-wrap
        Content-Type: text/plain; charset=utf-8

        Unsubscribe: https://lists.example.net/unsubscribe (anyone can write this)
        --list-wrap--
        """

    // MARK: - multipart/encrypted

    static let encrypted = """
        From: Alice Example <alice@example.org>
        To: Bob Example <bob@example.net>
        Subject: ...
        MIME-Version: 1.0
        Content-Type: multipart/encrypted;
         protocol="application/pgp-encrypted";
         boundary="enc-boundary"

        This is an OpenPGP/MIME encrypted message (RFC 4880 and 3156)
        --enc-boundary
        Content-Type: application/pgp-encrypted
        Content-Description: PGP/MIME version identification

        Version: 1

        --enc-boundary
        Content-Type: application/octet-stream; name="encrypted.asc"
        Content-Description: OpenPGP encrypted message
        Content-Disposition: inline; filename="encrypted.asc"

        \(fakeMessage)

        --enc-boundary--
        """

    // MARK: - Malformed and look-alikes

    /// Names the OpenPGP protocol, but the second part is not a signature.
    static let malformedSigned = """
        From: Mallory <mallory@example.net>
        Subject: Trust me
        MIME-Version: 1.0
        Content-Type: multipart/signed; protocol="application/pgp-signature"; boundary=b

        --b
        Content-Type: text/plain

        Signed, honestly.
        --b
        Content-Type: text/plain

        \(fakeSignature)
        --b--
        """

    /// S/MIME, not OpenPGP: no finding.
    static let smimeSigned = """
        From: Alice Example <alice@example.org>
        MIME-Version: 1.0
        Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256; boundary=s

        --s
        Content-Type: text/plain

        S/MIME body.
        --s
        Content-Type: application/pkcs7-signature; name=smime.p7s
        Content-Transfer-Encoding: base64

        VEVTVCBPTkxZ
        --s--
        """

    /// A plain message whose sender typed signed-looking text.
    static let plainLookingSigned = """
        From: Mallory <mallory@example.net>
        Subject: [PGP signed] Verified message
        X-PGP-Signed: yes
        MIME-Version: 1.0
        Content-Type: text/plain; charset=utf-8

        This message is PGP signed and verified.
        """

    // MARK: - Inline

    static let inlineSignedBody = """
        -----BEGIN PGP SIGNED MESSAGE-----
        Hash: SHA256

        Hello, this is a cleartext-signed message.
        - -- dash-escaped line
        \(fakeSignature)
        """

    static let inlineSigned = """
        From: Alice Example <alice@example.org>
        Subject: Inline signed
        MIME-Version: 1.0
        Content-Type: text/plain; charset=us-ascii

        \(inlineSignedBody)
        """

    /// Text before the armored block: the block is only part of the message.
    static let inlineEncryptedWithPreface = """
        From: Alice Example <alice@example.org>
        Subject: Inline encrypted
        MIME-Version: 1.0
        Content-Type: text/plain; charset=us-ascii
        Content-Transfer-Encoding: quoted-printable

        Added outside the encrypted block by anyone on the path.

        -----BEGIN PGP MESSAGE-----

        \(fakePayload.replacingOccurrences(of: "=", with: "=3D"))
        =3DTEST
        -----END PGP MESSAGE-----
        """

    /// A reply quoting someone's armored block: not this message's own.
    static let quotedArmorReply = """
        From: Bob Example <bob@example.net>
        Subject: Re: Inline encrypted
        MIME-Version: 1.0
        Content-Type: text/plain; charset=us-ascii

        I could not read this:

        > -----BEGIN PGP MESSAGE-----
        > \(fakePayload)
        > -----END PGP MESSAGE-----
        """

    /// A begin line without its end line.
    static let truncatedArmor = """
        From: Alice Example <alice@example.org>
        Content-Type: text/plain

        -----BEGIN PGP MESSAGE-----
        \(fakePayload)
        """

    // MARK: - Attachments

    static let keyAttachment = """
        From: Alice Example <alice@example.org>
        Subject: My public key
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="mix"

        --mix
        Content-Type: text/plain

        Key attached.
        --mix
        Content-Type: application/pgp-keys; name="0xTESTONLY.asc"
        Content-Disposition: attachment; filename="0xTESTONLY.asc"

        \(fakePublicKey)
        --mix
        Content-Type: application/octet-stream; name="report.pdf.sig"
        Content-Disposition: attachment; filename="report.pdf.sig"
        Content-Transfer-Encoding: base64

        VEVTVCBPTkxZ
        --mix
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="archive.tar.gpg"
        Content-Transfer-Encoding: base64

        VEVTVCBPTkxZ
        --mix--
        """

    static let plain = """
        From: Alice Example <alice@example.org>
        Subject: Lunch
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="alt"

        --alt
        Content-Type: text/plain

        Lunch at noon?
        --alt
        Content-Type: text/html

        <p>Lunch at noon?</p>
        --alt--
        """
}
