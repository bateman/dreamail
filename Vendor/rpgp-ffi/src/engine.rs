//! Safe Rust side of MishMail's OpenPGP engine (step 4B, scope B): verify
//! detached and cleartext signatures, decrypt, and read keys. Stateless:
//! every call receives the certificates and secret keys it may use; the app
//! stores them (Keychain, encrypted database), not this crate.
//!
//! Everything cryptographic is rPGP's. What lives here is certificate
//! *policy*, which rPGP leaves to the application: which key in a
//! certificate may have made a signature, and whether that certificate is
//! valid now (bindings verify, not revoked, not expired). The policy is
//! deliberately strict and simple; see `cert_state`.

use std::io::{BufReader, Cursor, Read};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use pgp::composed::{
    CleartextSignedMessage, Deserializable, DetachedSignature, Esk, Message, PublicOrSecret,
    SignedPublicKey, SignedSecretKey,
};
use pgp::errors::Error as PgpError;
use pgp::packet::{PublicKey, PublicSubkey, Signature, SignatureType};
use pgp::types::{KeyDetails, Password, VerifyingKey};
use serde::Serialize;

/// Upper bound on any single input, as a cheap guard in front of the parser
/// (rPGP has its own limits as well).
pub const MAX_INPUT: usize = 256 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum EngineError {
    Malformed,
    NoSecretKey,
    PassphraseRequired,
    Unsupported,
    Internal,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct KeySummary {
    pub fingerprint: String,
    pub user_ids: Vec<String>,
    pub has_secret: bool,
    pub created: u64,
    pub expires: Option<u64>,
    pub revoked: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum SignatureResult {
    Good { signer: KeySummary },
    Bad,
    UnknownKey { key_id: String },
    KeyNotValid { signer: KeySummary },
    Unsupported,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Decryption {
    /// Always true when decryption succeeds: legacy SED (no integrity check)
    /// is refused by rPGP's defaults, SEIPD v1 is MDC-checked before any
    /// plaintext is released, and SEIPD v2 is AEAD.
    pub integrity_protected: bool,
    pub signatures: Vec<SignatureResult>,
    #[serde(skip)]
    pub plaintext: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Cleartext {
    pub signatures: Vec<SignatureResult>,
    #[serde(skip)]
    pub signed_text: Vec<u8>,
}

fn now_secs(now: SystemTime) -> u64 {
    now.duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02X}")).collect()
}

fn check_size(data: &[u8]) -> Result<(), EngineError> {
    if data.len() > MAX_INPUT {
        Err(EngineError::Malformed)
    } else {
        Ok(())
    }
}

fn looks_armored(data: &[u8]) -> bool {
    let start = data.iter().position(|b| !b.is_ascii_whitespace()).unwrap_or(data.len());
    data[start..].starts_with(b"-----BEGIN ")
}

// MARK: - Keys

/// Every certificate and secret key in `data` (armored or binary, any
/// number of blocks). Unparseable data is an error; an empty input is none.
pub fn read_keys(data: &[u8]) -> Result<(Vec<SignedPublicKey>, Vec<SignedSecretKey>), EngineError> {
    check_size(data)?;
    let mut public = Vec::new();
    let mut secret = Vec::new();
    if data.iter().all(|b| b.is_ascii_whitespace()) {
        return Ok((public, secret));
    }
    if looks_armored(data) {
        // Several armored blocks may follow one another.
        let text = std::str::from_utf8(data).map_err(|_| EngineError::Malformed)?;
        for block in split_armor_blocks(text) {
            let (keys, _) = PublicOrSecret::from_armor_many(Cursor::new(block.as_bytes()))
                .map_err(|_| EngineError::Malformed)?;
            for key in keys {
                push_key(key.map_err(|_| EngineError::Malformed)?, &mut public, &mut secret);
            }
        }
    } else {
        let (keys, _) = PublicOrSecret::from_reader_many(Cursor::new(data))
            .map_err(|_| EngineError::Malformed)?;
        for key in keys {
            push_key(key.map_err(|_| EngineError::Malformed)?, &mut public, &mut secret);
        }
    }
    Ok((public, secret))
}

fn push_key(key: PublicOrSecret, public: &mut Vec<SignedPublicKey>, secret: &mut Vec<SignedSecretKey>) {
    match key {
        PublicOrSecret::Public(k) => public.push(k),
        PublicOrSecret::Secret(k) => secret.push(k),
    }
}

fn split_armor_blocks(text: &str) -> Vec<String> {
    let mut blocks = Vec::new();
    let mut current: Option<String> = None;
    for line in text.lines() {
        let trimmed = line.trim_end();
        if trimmed.starts_with("-----BEGIN PGP ") {
            current = Some(String::new());
        }
        if let Some(block) = current.as_mut() {
            block.push_str(trimmed);
            block.push('\n');
        }
        if trimmed.starts_with("-----END PGP ") {
            if let Some(block) = current.take() {
                blocks.push(block);
            }
        }
    }
    blocks
}

/// What the keys in `data` are, for the import screen. Nothing is stored.
pub fn inspect_keys(data: &[u8], now: SystemTime) -> Result<Vec<KeySummary>, EngineError> {
    let (public, secret) = read_keys(data)?;
    if public.is_empty() && secret.is_empty() {
        return Err(EngineError::Malformed);
    }
    let mut out: Vec<KeySummary> = public.iter().map(|k| summary(k, false, now)).collect();
    out.extend(secret.iter().map(|k| summary(&k.to_public_key(), true, now)));
    Ok(out)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CertState {
    Valid,
    Revoked,
    Expired,
    /// Self-signatures do not verify: nothing in it can be trusted.
    Broken,
}

/// Strict certificate policy:
/// - every binding, revocation and direct signature must verify against the
///   primary key (rPGP `verify_bindings`), else `Broken`;
/// - any key revocation signature means `Revoked`, whatever its reason
///   (soft revocations, such as "superseded", included);
/// - the expiration in the newest self-signature (user ID binding or direct
///   key signature), if any, decides `Expired` at `now`.
///
/// Not evaluated (stricter than needed, or left for later): signature
/// creation times against a key's validity window (an old message signed by
/// a key that has since expired reads as `key_not_valid`), and third-party
/// certifications (no web of trust).
fn cert_state(cert: &SignedPublicKey, now: SystemTime) -> CertState {
    if cert.verify_bindings().is_err() {
        return CertState::Broken;
    }
    if !cert.details.revocation_signatures.is_empty() {
        return CertState::Revoked;
    }
    match expiry(cert) {
        Some(at) if now_secs(now) >= at => CertState::Expired,
        _ => CertState::Valid,
    }
}

fn newest_self_signature(cert: &SignedPublicKey) -> Option<&Signature> {
    cert.details
        .users
        .iter()
        .flat_map(|u| u.signatures.iter())
        .chain(cert.details.direct_signatures.iter())
        .max_by_key(|s| s.created().map(|t| t.as_secs()).unwrap_or(0))
}

fn expiry(cert: &SignedPublicKey) -> Option<u64> {
    let created = u64::from(cert.primary_key.created_at().as_secs());
    newest_self_signature(cert)
        .and_then(|s| s.key_expiration_time())
        .map(|d| u64::from(d.as_secs()))
        .filter(|secs| *secs != 0)
        .map(|secs| created + secs)
}

fn summary(cert: &SignedPublicKey, has_secret: bool, now: SystemTime) -> KeySummary {
    let state = cert_state(cert, now);
    KeySummary {
        fingerprint: hex(cert.primary_key.fingerprint().as_bytes()),
        user_ids: cert
            .details
            .users
            .iter()
            .filter_map(|u| u.id.as_str().map(str::to_owned))
            .collect(),
        has_secret,
        created: u64::from(cert.primary_key.created_at().as_secs()),
        expires: expiry(cert),
        revoked: state == CertState::Revoked,
    }
}

// MARK: - Signatures

/// A key that may have issued a signature.
#[derive(Clone, Copy)]
enum Candidate<'a> {
    Primary(&'a PublicKey),
    Subkey(&'a PublicSubkey),
}

impl<'a> Candidate<'a> {
    fn as_dyn(self) -> &'a dyn VerifyingKey {
        match self {
            Candidate::Primary(k) => k,
            Candidate::Subkey(k) => k,
        }
    }

    fn verify_detached(self, sig: &Signature, data: &[u8]) -> bool {
        match self {
            Candidate::Primary(k) => sig.verify(k, data).is_ok(),
            Candidate::Subkey(k) => sig.verify(k, data).is_ok(),
        }
    }
}

/// Keys of `cert` that may have issued `sig`: the primary key and every
/// subkey with a verifying binding signature that allows signing and no
/// subkey revocation, filtered by the issuer the signature names.
fn issuer_candidates<'a>(cert: &'a SignedPublicKey, sig: &Signature) -> Vec<Candidate<'a>> {
    let names_issuer = |fingerprint: &[u8], key_id: &[u8]| {
        sig.issuer_fingerprint().iter().any(|f| f.as_bytes() == fingerprint)
            || sig.issuer_key_id().iter().any(|k| k.as_ref() == key_id)
    };
    let mut out: Vec<Candidate<'a>> = Vec::new();
    let primary = &cert.primary_key;
    if names_issuer(primary.fingerprint().as_bytes(), primary.legacy_key_id().as_ref()) {
        out.push(Candidate::Primary(primary));
    }
    for sub in &cert.public_subkeys {
        if !names_issuer(sub.key.fingerprint().as_bytes(), sub.key.legacy_key_id().as_ref()) {
            continue;
        }
        let bound = sub.verify_bindings(primary).is_ok();
        let revoked = sub
            .signatures
            .iter()
            .any(|s| s.typ() == Some(SignatureType::SubkeyRevocation));
        let may_sign = sub
            .signatures
            .iter()
            .any(|s| s.typ() == Some(SignatureType::SubkeyBinding) && s.key_flags().sign());
        if bound && !revoked && may_sign {
            out.push(Candidate::Subkey(&sub.key));
        }
    }
    out
}

fn issuer_label(sig: &Signature) -> String {
    if let Some(f) = sig.issuer_fingerprint().first() {
        return hex(f.as_bytes());
    }
    sig.issuer_key_id().first().map(|k| hex(k.as_ref())).unwrap_or_default()
}

/// One signature against every certificate given.
fn check_signature(
    sig: &Signature,
    certs: &[SignedPublicKey],
    now: SystemTime,
    verify: impl Fn(Candidate<'_>) -> bool,
) -> SignatureResult {
    let mut issuer_known = false;
    for cert in certs {
        let candidates = issuer_candidates(cert, sig);
        if candidates.is_empty() {
            continue;
        }
        issuer_known = true;
        if candidates.into_iter().any(&verify) {
            let summary = summary(cert, false, now);
            return match cert_state(cert, now) {
                CertState::Valid => SignatureResult::Good { signer: summary },
                CertState::Broken => SignatureResult::Bad,
                CertState::Revoked | CertState::Expired => {
                    SignatureResult::KeyNotValid { signer: summary }
                }
            };
        }
    }
    if issuer_known {
        SignatureResult::Bad
    } else {
        SignatureResult::UnknownKey { key_id: issuer_label(sig) }
    }
}

/// A detached signature (`application/pgp-signature`) over `data`, which
/// for PGP/MIME is the canonical (CRLF) signed part.
pub fn verify_detached(
    data: &[u8],
    signature: &[u8],
    certs: &[u8],
    now: SystemTime,
) -> Result<Vec<SignatureResult>, EngineError> {
    check_size(data)?;
    check_size(signature)?;
    let (certs, _) = read_keys(certs)?;
    let sigs: Vec<DetachedSignature> = if looks_armored(signature) {
        let (iter, _) = DetachedSignature::from_armor_many(Cursor::new(signature))
            .map_err(|_| EngineError::Malformed)?;
        iter.collect::<Result<_, _>>().map_err(|_| EngineError::Malformed)?
    } else {
        DetachedSignature::from_bytes_many(BufReader::new(Cursor::new(signature)))
            .map_err(|_| EngineError::Malformed)?
            .collect::<Result<_, _>>()
            .map_err(|_| EngineError::Malformed)?
    };
    if sigs.is_empty() {
        return Err(EngineError::Malformed);
    }
    Ok(sigs
        .iter()
        .map(|d| check_signature(&d.signature, &certs, now, |key| key.verify_detached(&d.signature, data)))
        .collect())
}

/// A cleartext-signed message. The signed text returned is rPGP's view of
/// it (dash-escaping undone, CRLF): the only text that may be shown as
/// signed.
pub fn verify_cleartext(message: &[u8], certs: &[u8], now: SystemTime) -> Result<Cleartext, EngineError> {
    check_size(message)?;
    let (certs, _) = read_keys(certs)?;
    let (msg, _) = CleartextSignedMessage::from_armor(Cursor::new(message))
        .map_err(|_| EngineError::Malformed)?;
    let text = msg.signed_text();
    let signatures = msg
        .signatures()
        .iter()
        .map(|sig| check_signature(sig, &certs, now, |key| key.verify_detached(sig, text.as_bytes())))
        .collect();
    Ok(Cleartext { signatures, signed_text: text.into_bytes() })
}

// MARK: - Decryption

/// Decrypts with any of `secret_keys` (unlocked with `passphrase`), then
/// verifies signatures inside against `certs` plus the secret keys' own
/// public halves.
pub fn decrypt(
    message: &[u8],
    secret_keys: &[u8],
    passphrase: &[u8],
    certs: &[u8],
    now: SystemTime,
) -> Result<Decryption, EngineError> {
    check_size(message)?;
    let (_, secrets) = read_keys(secret_keys)?;
    if secrets.is_empty() {
        return Err(EngineError::NoSecretKey);
    }
    let (mut certs, _) = read_keys(certs)?;
    certs.extend(secrets.iter().map(|k| k.to_public_key()));

    let parsed = if looks_armored(message) {
        Message::from_armor(BufReader::new(Cursor::new(message.to_vec()))).map(|(m, _)| m)
    } else {
        Message::from_bytes(BufReader::new(Cursor::new(message.to_vec())))
    }
    .map_err(|_| EngineError::Malformed)?;
    let Some((addressed, locked)) = recipients(&parsed, &secrets) else {
        return Err(EngineError::Malformed);
    };

    let password = Password::from(passphrase);
    let passwords: Vec<&Password> = secrets.iter().map(|_| &password).collect();
    let mut decrypted = parsed
        .decrypt_with_keys(passwords, secrets.iter().collect())
        .map_err(|e| map_decrypt_error(e, addressed, locked))?;
    if decrypted.is_compressed() {
        decrypted = decrypted.decompress().map_err(|_| EngineError::Malformed)?;
    }
    let mut plaintext = Vec::new();
    // For SEIPD v1 rPGP checks the MDC before releasing plaintext; a failed
    // check surfaces here as an error, and nothing is returned.
    decrypted.read_to_end(&mut plaintext).map_err(|_| EngineError::Malformed)?;

    let mut signatures = Vec::new();
    if decrypted.is_signed() {
        let count = signature_count(&decrypted);
        for index in 0..count {
            let Some(sig) = nested_signature(&decrypted, index) else { continue };
            signatures.push(check_signature(&sig, &certs, now, |key| {
                decrypted.verify_nested_explicit(index, key.as_dyn()).is_ok()
            }));
        }
    }
    Ok(Decryption { integrity_protected: true, signatures, plaintext })
}

/// Whether any of `secrets` is a recipient of the message, and whether such
/// a recipient key is passphrase-protected. None when the message is not
/// encrypted.
fn recipients(message: &Message<'_>, secrets: &[SignedSecretKey]) -> Option<(bool, bool)> {
    let Message::Encrypted { esk, .. } = message else { return None };
    let mut addressed = false;
    let mut locked = false;
    for pkesk in esk.iter().filter_map(|e| match e {
        Esk::PublicKeyEncryptedSessionKey(p) => Some(p),
        Esk::SymKeyEncryptedSessionKey(_) => None,
    }) {
        for key in secrets {
            if pkesk.match_identity(&key.primary_key) {
                addressed = true;
                locked |= key.primary_key.secret_params().is_encrypted();
            }
            for sub in &key.secret_subkeys {
                if pkesk.match_identity(&sub.key) {
                    addressed = true;
                    locked |= sub.key.secret_params().is_encrypted();
                }
            }
        }
    }
    Some((addressed, locked))
}

/// rPGP reports "no usable key" (including a wrong passphrase, which leaves
/// the key unusable) as `MissingKey`; which one it was follows from whether
/// a recipient key is ours and locked.
fn map_decrypt_error(error: PgpError, addressed: bool, locked: bool) -> EngineError {
    match error {
        PgpError::MissingKey if !addressed => EngineError::NoSecretKey,
        PgpError::MissingKey if locked => EngineError::PassphraseRequired,
        PgpError::Unsupported { .. } | PgpError::Unimplemented { .. } => EngineError::Unsupported,
        _ => EngineError::Malformed,
    }
}

fn signature_count(message: &Message<'_>) -> usize {
    match message {
        Message::Signed { reader, .. } => reader.num_signatures(),
        _ => 0,
    }
}

fn nested_signature(message: &Message<'_>, index: usize) -> Option<Signature> {
    match message {
        Message::Signed { reader, .. } => reader.signature(index).cloned(),
        _ => None,
    }
}

pub fn system_time(unix_secs: i64) -> SystemTime {
    if unix_secs <= 0 {
        UNIX_EPOCH
    } else {
        UNIX_EPOCH + Duration::from_secs(unix_secs as u64)
    }
}
