//! Round trips through rPGP with keys generated at test time. No key
//! material is stored in the repository.

use std::time::SystemTime;

use mishmail_rpgp::engine::{self, EngineError, SignatureResult};
use pgp::composed::{
    ArmorOptions, CleartextSignedMessage, DetachedSignature, EncryptionCaps, KeyType,
    MessageBuilder, SecretKeyParamsBuilder, SignedSecretKey, SubkeyParamsBuilder,
};
use pgp::crypto::{ecc_curve::ECCCurve, hash::HashAlgorithm, sym::SymmetricKeyAlgorithm};
use pgp::packet::SignatureType;
use pgp::types::Password;
use rand::thread_rng;
use smallvec::smallvec;

fn generate(uid: &str, passphrase: Option<&str>) -> SignedSecretKey {
    generate_with(uid, &[], passphrase)
}

fn generate_with(uid: &str, more_uids: &[&str], passphrase: Option<&str>) -> SignedSecretKey {
    let mut params = SecretKeyParamsBuilder::default();
    params
        .key_type(KeyType::Ed25519Legacy)
        .can_certify(true)
        .can_sign(true)
        .primary_user_id(uid.into())
        .user_ids(more_uids.iter().map(|s| (*s).to_owned()).collect())
        .passphrase(passphrase.map(str::to_owned))
        .preferred_symmetric_algorithms(smallvec![SymmetricKeyAlgorithm::AES256])
        .preferred_hash_algorithms(smallvec![HashAlgorithm::Sha256])
        .preferred_compression_algorithms(smallvec![])
        .subkeys(vec![SubkeyParamsBuilder::default()
            .key_type(KeyType::ECDH(ECCCurve::Curve25519Legacy))
            .passphrase(passphrase.map(str::to_owned))
            .can_encrypt(EncryptionCaps::All)
            .build()
            .unwrap()]);
    params.build().unwrap().generate(thread_rng()).unwrap()
}

fn public_armor(key: &SignedSecretKey) -> Vec<u8> {
    key.to_public_key().to_armored_bytes(ArmorOptions::default()).unwrap()
}

fn secret_armor(key: &SignedSecretKey) -> Vec<u8> {
    key.to_armored_bytes(ArmorOptions::default()).unwrap()
}

fn detached(key: &SignedSecretKey, pw: &str, data: &[u8]) -> Vec<u8> {
    DetachedSignature::sign_binary_data(thread_rng(), &key.primary_key, &Password::from(pw),
                                        HashAlgorithm::Sha256, data)
        .unwrap()
        .to_armored_bytes(ArmorOptions::default())
        .unwrap()
}

fn now() -> SystemTime {
    SystemTime::now()
}

#[test]
fn inspect_reports_fingerprint_user_ids_and_secrecy() {
    let alice = generate("Alice <alice@example.org>", None);
    let keys = engine::inspect_keys(&public_armor(&alice), now()).unwrap();
    assert_eq!(keys.len(), 1);
    assert_eq!(keys[0].user_ids, vec!["Alice <alice@example.org>".to_owned()]);
    assert!(!keys[0].has_secret);
    assert!(!keys[0].revoked);
    assert_eq!(keys[0].expires, None);
    assert_eq!(keys[0].fingerprint.len(), 40);

    let both = [public_armor(&generate("Bob <bob@example.net>", None)), secret_armor(&alice)].concat();
    let keys = engine::inspect_keys(&both, now()).unwrap();
    assert_eq!(keys.iter().filter(|k| k.has_secret).count(), 1);

    assert_eq!(engine::inspect_keys(b"not a key", now()), Err(EngineError::Malformed));
    assert_eq!(engine::inspect_keys(b"", now()), Err(EngineError::Malformed));
}

#[test]
fn detached_good_bad_and_unknown() {
    let alice = generate("Alice <alice@example.org>", None);
    let data = b"Content-Type: text/plain\r\n\r\nHello\r\n";
    let sig = detached(&alice, "", data);
    let certs = public_armor(&alice);

    let good = engine::verify_detached(data, &sig, &certs, now()).unwrap();
    assert!(matches!(&good[..], [SignatureResult::Good { signer }]
        if signer.user_ids == ["Alice <alice@example.org>"]));

    let bad = engine::verify_detached(b"Content-Type: text/plain\r\n\r\nHellO\r\n", &sig, &certs, now()).unwrap();
    assert_eq!(bad, vec![SignatureResult::Bad]);

    let other = public_armor(&generate("Mallory <mallory@example.net>", None));
    let unknown = engine::verify_detached(data, &sig, &other, now()).unwrap();
    assert!(matches!(&unknown[..], [SignatureResult::UnknownKey { key_id }] if !key_id.is_empty()));

    let none = engine::verify_detached(data, &sig, b"", now()).unwrap();
    assert!(matches!(&none[..], [SignatureResult::UnknownKey { .. }]));
}

#[test]
fn malformed_inputs_are_errors_not_panics() {
    let alice = generate("Alice <alice@example.org>", None);
    let certs = public_armor(&alice);
    for garbage in [&b""[..], b"-----BEGIN PGP SIGNATURE-----\n\nAAAA\n-----END PGP SIGNATURE-----\n",
                    b"\x89\x01\x02", b"plain text"] {
        assert_eq!(engine::verify_detached(b"data", garbage, &certs, now()), Err(EngineError::Malformed));
        assert!(engine::decrypt(garbage, &secret_armor(&alice), b"", b"", now()).is_err());
        assert!(engine::verify_cleartext(garbage, &certs, now()).is_err());
    }
    assert_eq!(engine::verify_detached(b"data", &detached(&alice, "", b"data"), b"junk", now()),
               Err(EngineError::Malformed));
}

#[test]
fn cleartext_signed_text_is_what_was_signed() {
    let alice = generate("Alice <alice@example.org>", None);
    let msg = CleartextSignedMessage::sign(thread_rng(), "Hello\n- dashes\n", &alice.primary_key,
                                           &Password::empty())
        .unwrap()
        .to_armored_bytes(ArmorOptions::default())
        .unwrap();
    let result = engine::verify_cleartext(&msg, &public_armor(&alice), now()).unwrap();
    assert!(matches!(&result.signatures[..], [SignatureResult::Good { .. }]));
    assert_eq!(String::from_utf8(result.signed_text).unwrap(), "Hello\r\n- dashes\r\n");
}

fn encrypt(to: &SignedSecretKey, signer: Option<&SignedSecretKey>, v2: bool, plaintext: &[u8]) -> Vec<u8> {
    let mut rng = thread_rng();
    let public = to.to_public_key();
    let builder = MessageBuilder::from_bytes("", plaintext.to_vec());
    if v2 {
        let mut b = builder.seipd_v2(&mut rng, SymmetricKeyAlgorithm::AES256,
                                     pgp::crypto::aead::AeadAlgorithm::Ocb,
                                     pgp::crypto::aead::ChunkSize::default());
        b.encrypt_to_key(&mut rng, &public.public_subkeys[0]).unwrap();
        if let Some(s) = signer {
            b.sign(&s.primary_key, Password::empty(), HashAlgorithm::Sha256);
        }
        b.to_armored_string(&mut rng, ArmorOptions::default()).unwrap().into_bytes()
    } else {
        let mut b = builder.seipd_v1(&mut rng, SymmetricKeyAlgorithm::AES256);
        b.encrypt_to_key(&mut rng, &public.public_subkeys[0]).unwrap();
        if let Some(s) = signer {
            b.sign(&s.primary_key, Password::empty(), HashAlgorithm::Sha256);
        }
        b.to_armored_string(&mut rng, ArmorOptions::default()).unwrap().into_bytes()
    }
}

#[test]
fn decrypt_round_trips_with_integrity_and_inner_signature() {
    let alice = generate("Alice <alice@example.org>", None);
    let bob = generate("Bob <bob@example.net>", None);
    for v2 in [false, true] {
        let msg = encrypt(&bob, Some(&alice), v2, b"secret text");
        let out = engine::decrypt(&msg, &secret_armor(&bob), b"", &public_armor(&alice), now()).unwrap();
        assert_eq!(out.plaintext, b"secret text");
        assert!(out.integrity_protected);
        assert!(matches!(&out.signatures[..], [SignatureResult::Good { signer }]
            if signer.user_ids == ["Alice <alice@example.org>"]), "v2={v2}: {:?}", out.signatures);

        // Without Alice's certificate the signature is from an unknown key.
        let out = engine::decrypt(&msg, &secret_armor(&bob), b"", b"", now()).unwrap();
        assert!(matches!(&out.signatures[..], [SignatureResult::UnknownKey { .. }]));
    }
}

#[test]
fn decrypt_errors() {
    let bob = generate("Bob <bob@example.net>", None);
    let eve = generate("Eve <eve@example.net>", None);
    let msg = encrypt(&bob, None, true, b"secret");
    assert_eq!(engine::decrypt(&msg, &secret_armor(&eve), b"", b"", now()).map(|_| ()),
               Err(EngineError::NoSecretKey));
    assert_eq!(engine::decrypt(&msg, &public_armor(&bob), b"", b"", now()).map(|_| ()),
               Err(EngineError::NoSecretKey), "a public key cannot decrypt");

    let locked = generate("Carol <carol@example.net>", Some("correct horse"));
    let msg = encrypt(&locked, None, true, b"secret");
    let wrong = engine::decrypt(&msg, &secret_armor(&locked), b"wrong", b"", now()).map(|_| ());
    assert_eq!(wrong, Err(EngineError::PassphraseRequired));
    let empty = engine::decrypt(&msg, &secret_armor(&locked), b"", b"", now()).map(|_| ());
    assert_eq!(empty, Err(EngineError::PassphraseRequired));
    let right = engine::decrypt(&msg, &secret_armor(&locked), b"correct horse", b"", now()).unwrap();
    assert_eq!(right.plaintext, b"secret");
}

#[test]
fn tampered_ciphertext_releases_nothing() {
    let bob = generate("Bob <bob@example.net>", None);
    for v2 in [false, true] {
        let armored = encrypt(&bob, None, v2, &[b'x'; 4096]);
        let mut binary = Vec::new();
        // Dearmor and flip a byte near the end (inside the encrypted data,
        // after the session-key packet).
        let text = String::from_utf8(armored.clone()).unwrap();
        let body: String = text.lines().filter(|l| !l.starts_with("-----") && !l.starts_with('=') && !l.is_empty())
            .collect();
        binary.extend(base64_decode(&body));
        let at = binary.len() - 40;
        binary[at] ^= 0x01;
        let out = engine::decrypt(&binary, &secret_armor(&bob), b"", b"", now());
        assert!(out.is_err(), "v2={v2}: tampered message decrypted");
    }
}

fn base64_decode(s: &str) -> Vec<u8> {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = Vec::new();
    let mut acc = 0u32;
    let mut bits = 0;
    for c in s.bytes() {
        let Some(v) = T.iter().position(|&t| t == c) else { continue };
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    out
}

#[test]
fn ffi_round_trip_and_garbage() {
    use mishmail_rpgp::{mm_pgp_free, mm_pgp_inspect_keys, mm_pgp_verify_detached};
    let alice = generate("Alice <alice@example.org>", None);
    let certs = public_armor(&alice);
    let data = b"payload";
    let sig = detached(&alice, "", data);
    unsafe {
        let r = mm_pgp_verify_detached(data.as_ptr(), data.len(), sig.as_ptr(), sig.len(),
                                       certs.as_ptr(), certs.len(), 0);
        let json = std::str::from_utf8(std::slice::from_raw_parts(r.json.ptr, r.json.len)).unwrap().to_owned();
        assert!(json.contains("\"ok\":true") && json.contains("\"status\":\"good\""), "{json}");
        assert!(r.data.ptr.is_null());
        mm_pgp_free(r);

        let r = mm_pgp_inspect_keys(b"\xff\xfe".as_ptr(), 2, 0);
        let json = std::str::from_utf8(std::slice::from_raw_parts(r.json.ptr, r.json.len)).unwrap().to_owned();
        assert_eq!(json, r#"{"error":"malformed","ok":false}"#);
        mm_pgp_free(r);

        let r = mm_pgp_verify_detached(std::ptr::null(), 0, std::ptr::null(), 0, std::ptr::null(), 0, 0);
        mm_pgp_free(r);

    }
}

/// A third-party certification on a user ID (common in GnuPG exports) must
/// not make a valid key look broken: rPGP's `verify_bindings` would reject
/// it, our policy ignores signatures not made by the primary key.
#[test]
fn third_party_certifications_do_not_break_a_key() {
    let alice = generate("Alice <alice@example.org>", None);
    let bob = generate("Bob <bob@example.net>", None);
    let mut cert = alice.to_public_key();
    let certified = cert.details.users[0]
        .id
        .sign_third_party(thread_rng(), &bob.primary_key, &Password::empty(), &cert.primary_key,
                          SignatureType::CertGeneric)
        .unwrap();
    cert.details.users[0].signatures.extend(certified.signatures);
    assert!(cert.verify_bindings().is_err(), "rPGP alone would call this key broken");

    let data = b"payload";
    let sig = detached(&alice, "", data);
    let certs = cert.to_armored_bytes(ArmorOptions::default()).unwrap();
    let result = engine::verify_detached(data, &sig, &certs, now()).unwrap();
    assert!(matches!(&result[..], [SignatureResult::Good { .. }]), "{result:?}");
}

/// A user ID revoked by the key owner is not listed, so it cannot vouch for
/// a sender; the other user IDs stay.
#[test]
fn revoked_user_ids_are_left_out() {
    let alice = generate_with("Alice <alice@example.org>", &["Old <old@example.org>"], None);
    let mut cert = alice.to_public_key();
    let index = cert.details.users.iter().position(|u| u.id.as_str() == Some("Old <old@example.org>")).unwrap();
    use pgp::packet::{SignatureConfig, Subpacket, SubpacketData};
    use pgp::types::{KeyDetails, Tag, Timestamp};
    let mut config = SignatureConfig::from_key(thread_rng(), &alice.primary_key,
                                               SignatureType::CertRevocation).unwrap();
    config.hashed_subpackets = vec![
        Subpacket::regular(SubpacketData::SignatureCreationTime(Timestamp::now())).unwrap(),
        Subpacket::regular(SubpacketData::IssuerFingerprint(alice.primary_key.fingerprint())).unwrap(),
    ];
    config.unhashed_subpackets =
        vec![Subpacket::regular(SubpacketData::IssuerKeyId(alice.primary_key.legacy_key_id())).unwrap()];
    let revocation = config
        .sign_certification(&alice.primary_key, &cert.primary_key, &Password::empty(), Tag::UserId,
                            &cert.details.users[index].id)
        .unwrap();
    cert.details.users[index].signatures.push(revocation);
    let keys = engine::inspect_keys(&cert.to_armored_bytes(ArmorOptions::default()).unwrap(), now()).unwrap();
    assert_eq!(keys[0].user_ids, vec!["Alice <alice@example.org>".to_owned()]);
    assert!(!keys[0].revoked, "a revoked user ID is not a revoked key");
}

/// A self-signature that does not verify makes the key broken: a good
/// detached signature by it reads as bad, not good.
#[test]
fn a_broken_self_signature_makes_signatures_bad() {
    let alice = generate("Alice <alice@example.org>", None);
    let mut cert = alice.to_public_key();
    // Move Alice's self-signature onto a user ID it was not made for.
    let sig = cert.details.users[0].signatures[0].clone();
    cert.details.users[0].id = pgp::packet::UserId::from_str(Default::default(), "Mallory <mallory@example.net>").unwrap();
    cert.details.users[0].signatures = vec![sig];
    let data = b"payload";
    let certs = cert.to_armored_bytes(ArmorOptions::default()).unwrap();
    let result = engine::verify_detached(data, &detached(&alice, "", data), &certs, now()).unwrap();
    assert_eq!(result, vec![SignatureResult::Bad]);
}
