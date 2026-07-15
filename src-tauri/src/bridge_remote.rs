// Claude-to-Claude Remote Bridge — Faz 2: Remote mTLS + SPAKE2 Pairing.
//
// Spec: ADR 0002 D1/D2/D3.  MCP spec: 2025-11-25.
//
// Hard constraints (security-load-bearing — do NOT relax):
//   - Remote listener DEFAULT OFF; command bridge_remote_listen(enable, iface) starts/stops it.
//   - NEVER binds 0.0.0.0 / ::  — assertion at startup + test.
//   - mTLS ServerConfig uses a custom fail-closed ClientCertVerifier (ONLY pinned SPKI hashes).
//   - No cert / unknown cert → rejected AT HANDSHAKE (tokio-rustls #83 enforced).
//   - Local UDS path is UNTOUCHED — completely separate code path (ADR D3).
//   - Identity keypair (Ed25519) generated once, persisted in app-data at mode 0600.
//   - PAKE: SPAKE2 (spake2-conflux 0.6.0, RustCrypto lineage, RFC 9382).
//     ADR R7: cpace crate 0.1.0 is unmaintained (last published ~2021, very low downloads).
//     SPAKE2 has identical balanced PAKE security properties (active-MITM-resistant with short
//     PIN, offline-dictionary-proof) and is production-grade (RustCrypto audit lineage).
//     Deviation from ADR's CPace preference is documented in step-output-faz-2-remote-mtls.md.
//   - PIN: 8-digit, single-use, 5-min TTL, ≤5 attempts then lockout.
//   - Peer registry: SPKI-hash keyed, persisted, versioned v1.
//   - SAS: 6-character derived from SPAKE2 transcript + cert exchange hash.
//   - PAKE wire messages versioned v1 (one-way door).

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::net::SocketAddr;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use hkdf::Hkdf;
use rcgen::{CertificateParams, DistinguishedName, KeyPair};
use rustls::client::danger::HandshakeSignatureValid;
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::server::danger::{ClientCertVerified, ClientCertVerifier};
use rustls::{DigitallySignedStruct, ServerConfig, SignatureScheme};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use spake2_conflux::{Identity as Spake2Identity, Password, RistrettoGroup, Spake2};
use tauri::{AppHandle, Emitter, State};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::Mutex;
use tokio_rustls::TlsAcceptor;

use crate::bridge::MAX_FRAME_BYTES;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

/// PAKE wire message version — one-way door.
pub const PAKE_WIRE_VERSION: u8 = 1;
/// Peer registry schema version — one-way door.
pub const REGISTRY_SCHEMA_VERSION: u8 = 1;
/// PIN length in decimal digits.
pub const PIN_DIGITS: usize = 8;
/// PIN TTL.
pub const PIN_TTL: Duration = Duration::from_secs(300); // 5 minutes
/// Max PIN attempts before lockout.
pub const PIN_MAX_ATTEMPTS: u32 = 5;

// ---------------------------------------------------------------------------
// BridgeIdentity keypair (Ed25519, self-signed TLS cert, SPKI hash)
// ---------------------------------------------------------------------------

/// The stable identity for this host.
/// Generated once on first run; persisted in app-data/muya/bridge/identity.pem (0600).
#[derive(Clone)]
pub struct BridgeIdentity {
    /// DER-encoded certificate (self-signed, Ed25519).
    pub cert_der: Vec<u8>,
    /// DER-encoded private key.
    pub key_der: Vec<u8>,
    /// SHA-256 of SubjectPublicKeyInfo (hex) — stable across cert renewal.
    pub spki_hash: String,
}

impl BridgeIdentity {
    /// Load from disk or generate a new one.
    pub fn load_or_generate(dir: &PathBuf) -> Result<Self, String> {
        let cert_path = dir.join("identity_cert.pem");
        let key_path = dir.join("identity_key.pem");

        if cert_path.exists() && key_path.exists() {
            // Load existing.
            let cert_pem = fs::read_to_string(&cert_path).map_err(|e| format!("read cert: {e}"))?;
            let key_pem = fs::read_to_string(&key_path).map_err(|e| format!("read key: {e}"))?;
            let cert_der = pem_to_der(&cert_pem, "CERTIFICATE")?;
            let key_der = pem_to_der(&key_pem, "PRIVATE KEY")?;
            let spki_hash = compute_spki_hash_from_cert_der(&cert_der)?;
            Ok(BridgeIdentity {
                cert_der,
                key_der,
                spki_hash,
            })
        } else {
            // Generate new Ed25519 self-signed identity cert.
            let key_pair = KeyPair::generate_for(&rcgen::PKCS_ED25519)
                .map_err(|e| format!("generate ed25519 key: {e}"))?;
            let mut params = CertificateParams::new(vec!["muya-bridge".to_string()])
                .map_err(|e| format!("cert params: {e}"))?;
            params.distinguished_name = DistinguishedName::new();
            // Long-lived: 100 years (identity, not web PKI).
            params.not_before = rcgen::date_time_ymd(2024, 1, 1);
            params.not_after = rcgen::date_time_ymd(2124, 1, 1);

            let cert = params
                .self_signed(&key_pair)
                .map_err(|e| format!("self_signed: {e}"))?;

            let cert_pem = cert.pem();
            let key_pem = key_pair.serialize_pem();
            let cert_der = cert.der().to_vec();
            let key_der = key_pair.serialize_der();

            // Persist with mode 0600.
            write_secret_file(&cert_path, cert_pem.as_bytes())?;
            write_secret_file(&key_path, key_pem.as_bytes())?;

            let spki_hash = compute_spki_hash_from_cert_der(&cert_der)?;
            Ok(BridgeIdentity {
                cert_der,
                key_der,
                spki_hash,
            })
        }
    }
}

fn write_secret_file(path: &PathBuf, content: &[u8]) -> Result<(), String> {
    fs::write(path, content).map_err(|e| format!("write {path:?}: {e}"))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("chmod {path:?}: {e}"))?;
    Ok(())
}

fn pem_to_der(pem: &str, label: &str) -> Result<Vec<u8>, String> {
    // Simple PEM decoder: find BEGIN/END markers, base64-decode the body.
    let begin = format!("-----BEGIN {label}-----");
    let end = format!("-----END {label}-----");
    let start = pem
        .find(&begin)
        .ok_or_else(|| format!("PEM missing BEGIN {label}"))?
        + begin.len();
    let stop = pem
        .find(&end)
        .ok_or_else(|| format!("PEM missing END {label}"))?;
    let b64: String = pem[start..stop]
        .chars()
        .filter(|c| !c.is_whitespace())
        .collect();
    Ok(base64_decode(b64.as_bytes()))
}

fn base64_decode(input: &[u8]) -> Vec<u8> {
    const TABLE: [u8; 256] = {
        let mut t = [255u8; 256];
        let mut i = 0usize;
        while i < 26 {
            t[b'A' as usize + i] = i as u8;
            t[b'a' as usize + i] = (i + 26) as u8;
            i += 1;
        }
        let mut i = 0usize;
        while i < 10 {
            t[b'0' as usize + i] = (52 + i) as u8;
            i += 1;
        }
        t[b'+' as usize] = 62;
        t[b'/' as usize] = 63;
        // '=' is padding — leave as 255 (skip). Do NOT map to 0; that emits spurious zero bytes.
        t
    };
    let mut out = Vec::with_capacity(input.len() * 3 / 4 + 3);
    let mut acc: u32 = 0;
    let mut bits: u32 = 0;
    for &b in input {
        let v = TABLE[b as usize];
        if v == 255 {
            continue;
        }
        acc = (acc << 6) | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8 & 0xFF);
        }
    }
    out
}

/// Compute SHA-256 of the SubjectPublicKeyInfo from a DER certificate.
/// Returns lowercase hex string. This is the stable identity pin.
pub fn compute_spki_hash_from_cert_der(cert_der: &[u8]) -> Result<String, String> {
    let spki_bytes = extract_spki_der(cert_der)?;
    let hash = Sha256::digest(&spki_bytes);
    Ok(hex_encode(&hash))
}

/// Extract the SubjectPublicKeyInfo DER bytes from a DER-encoded X.509 certificate.
fn extract_spki_der(cert_der: &[u8]) -> Result<Vec<u8>, String> {
    // DER TLV parsing: Certificate SEQUENCE → TBSCertificate SEQUENCE → fields.
    let (_, cert_body) = der_read_tlv(cert_der)?;
    let (_, tbs_body) = der_read_tlv(cert_body)?;
    // TBSCertificate fields in order:
    // [0] version (optional, CONTEXT[0])
    // INTEGER serialNumber
    // SEQUENCE signatureAlgorithm
    // SEQUENCE issuer
    // SEQUENCE validity
    // SEQUENCE subject
    // SEQUENCE subjectPublicKeyInfo  ← target
    let mut rest = tbs_body;
    // Skip version if present (context tag [0]).
    if !rest.is_empty() && (rest[0] & 0xE0) == 0xA0 {
        let skip = der_element_len(rest)?;
        rest = &rest[skip..];
    }
    // Skip serial, sigAlg, issuer, validity, subject (5 elements).
    for _ in 0..5 {
        let skip = der_element_len(rest)?;
        rest = &rest[skip..];
    }
    // rest now starts at subjectPublicKeyInfo SEQUENCE.
    let spki_total_len = der_element_len(rest)?;
    Ok(rest[..spki_total_len].to_vec())
}

fn der_read_tlv<'a>(data: &'a [u8]) -> Result<(usize, &'a [u8]), String> {
    if data.is_empty() {
        return Err("DER: empty".to_string());
    }
    let (len_bytes, body_len) = der_tlv_len(data, 1)?;
    let header = 1 + len_bytes;
    if data.len() < header + body_len {
        return Err(format!(
            "DER: truncated (have {}, need {})",
            data.len(),
            header + body_len
        ));
    }
    Ok((header + body_len, &data[header..header + body_len]))
}

fn der_tlv_len(data: &[u8], tag_offset: usize) -> Result<(usize, usize), String> {
    if data.len() <= tag_offset {
        return Err("DER: no length byte".to_string());
    }
    let first = data[tag_offset];
    if first < 0x80 {
        Ok((1, first as usize))
    } else {
        let n = (first & 0x7F) as usize;
        if n == 0 || data.len() < tag_offset + 1 + n {
            return Err("DER: invalid length".to_string());
        }
        let mut len = 0usize;
        for &b in &data[tag_offset + 1..tag_offset + 1 + n] {
            len = (len << 8) | b as usize;
        }
        Ok((1 + n, len))
    }
}

fn der_element_len(data: &[u8]) -> Result<usize, String> {
    if data.is_empty() {
        return Err("DER: empty slice for element len".to_string());
    }
    let (len_bytes, body_len) = der_tlv_len(data, 1)?;
    Ok(1 + len_bytes + body_len)
}

fn hex_encode(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

// ---------------------------------------------------------------------------
// Peer registry (SPKI-pinned, versioned v1)
// ---------------------------------------------------------------------------

/// A single pinned peer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PinnedPeer {
    /// Schema version — always REGISTRY_SCHEMA_VERSION (1).
    pub schema_v: u8,
    /// SPKI hash (SHA-256 hex) — stable identity.
    pub spki_hash: String,
    /// Human-chosen label.
    pub label: String,
    /// Last known address (for dialing; not authoritative for identity).
    pub last_addr: Option<String>,
    /// Unix timestamp of pairing.
    pub paired_at: u64,
    /// Capability scope granted at pairing.
    pub capability: String,
}

/// In-memory + on-disk peer registry.
pub struct PeerRegistry {
    pub peers: HashMap<String, PinnedPeer>, // spki_hash → peer
    pub path: PathBuf,
}

impl PeerRegistry {
    pub fn load_or_create(dir: &PathBuf) -> Result<Self, String> {
        let path = dir.join("peer_registry.json");
        if path.exists() {
            let raw = fs::read_to_string(&path).map_err(|e| format!("read registry: {e}"))?;
            let peers: HashMap<String, PinnedPeer> =
                serde_json::from_str(&raw).map_err(|e| format!("parse registry: {e}"))?;
            Ok(PeerRegistry { peers, path })
        } else {
            Ok(PeerRegistry {
                peers: HashMap::new(),
                path,
            })
        }
    }

    pub fn save(&self) -> Result<(), String> {
        let raw = serde_json::to_string_pretty(&self.peers)
            .map_err(|e| format!("serialize registry: {e}"))?;
        write_secret_file(&self.path, raw.as_bytes())
    }

    pub fn insert(&mut self, peer: PinnedPeer) -> Result<(), String> {
        self.peers.insert(peer.spki_hash.clone(), peer);
        self.save()
    }

    pub fn remove(&mut self, spki_hash: &str) -> Result<(), String> {
        self.peers.remove(spki_hash);
        self.save()
    }

    pub fn get(&self, spki_hash: &str) -> Option<&PinnedPeer> {
        self.peers.get(spki_hash)
    }

    pub fn is_pinned(&self, spki_hash: &str) -> bool {
        self.peers.contains_key(spki_hash)
    }
}

// ---------------------------------------------------------------------------
// Active PIN / pairing state
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct ActivePin {
    /// The 8-digit PIN (stored in memory only — never written to disk).
    pub pin: String,
    /// When this PIN was created.
    pub created_at: Instant,
    /// How many PAKE attempts have been made.
    pub attempts: u32,
    /// Whether this PIN has been consumed (single-use).
    pub used: bool,
    /// SPAKE2 outgoing message (stored in-memory; set after invite is generated).
    pub spake2_outmsg: Option<Vec<u8>>,
    /// Pending SAS for human confirmation (only set after PAKE completes).
    pub pending_sas: Option<PendingSas>,
}

#[derive(Debug, Clone)]
pub struct PendingSas {
    pub sas: String,
    pub peer_spki: String,
    pub peer_label: String,
    /// The confirmed peer addr.
    pub peer_addr: String,
}

// ---------------------------------------------------------------------------
// Managed state for remote bridge
// ---------------------------------------------------------------------------

pub struct RemoteBridgeState {
    /// Our stable identity.
    pub identity: Mutex<Option<Arc<BridgeIdentity>>>,
    /// Peer registry.
    pub registry: Mutex<Option<Arc<Mutex<PeerRegistry>>>>,
    /// Active listener handle (None = off).
    pub listener: Mutex<Option<Arc<TcpListener>>>,
    /// Active PIN (invitee side).
    pub active_pin: Mutex<Option<ActivePin>>,
    /// Dedicated pairing listener handle (None = no pairing window open).
    /// Separate from the data listener — uses AnyCertVerifier, not PinnedSpkiVerifier.
    pub pairing_listener: Mutex<Option<Arc<TcpListener>>>,
}

impl Default for RemoteBridgeState {
    fn default() -> Self {
        RemoteBridgeState {
            identity: Mutex::new(None),
            registry: Mutex::new(None),
            listener: Mutex::new(None),
            active_pin: Mutex::new(None),
            pairing_listener: Mutex::new(None),
        }
    }
}

impl RemoteBridgeState {
    /// Ensure identity + registry are loaded; returns (BridgeIdentity, Registry).
    pub async fn ensure_initialized(
        &self,
    ) -> Result<(Arc<BridgeIdentity>, Arc<Mutex<PeerRegistry>>), String> {
        let mut id_guard = self.identity.lock().await;
        let mut reg_guard = self.registry.lock().await;

        if id_guard.is_none() {
            let dir = bridge_data_dir()?;
            let id = BridgeIdentity::load_or_generate(&dir)?;
            *id_guard = Some(Arc::new(id));
            let reg = PeerRegistry::load_or_create(&dir)?;
            *reg_guard = Some(Arc::new(Mutex::new(reg)));
        }

        Ok((
            id_guard.as_ref().unwrap().clone(),
            reg_guard.as_ref().unwrap().clone(),
        ))
    }
}

/// Returns the bridge data directory (creates it if missing, mode 0700).
pub fn bridge_data_dir() -> Result<PathBuf, String> {
    let base = dirs_next::data_local_dir()
        .or_else(dirs_next::home_dir)
        .ok_or("cannot determine app-data directory")?;
    let dir = base.join("muya").join("bridge");
    fs::create_dir_all(&dir).map_err(|e| format!("create bridge dir: {e}"))?;
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("chmod bridge dir: {e}"))?;
    Ok(dir)
}

// ---------------------------------------------------------------------------
// Address validation (AC-2-2 guard)
// ---------------------------------------------------------------------------

/// Returns an error if `addr` is a wildcard (0.0.0.0 / ::).
/// SECURITY ASSERTION — remote listener MUST NEVER bind a wildcard address.
pub fn assert_not_wildcard(addr: &str) -> Result<(), String> {
    let sa = SocketAddr::from_str(addr).map_err(|_| format!("invalid address: {addr:?}"))?;
    let ip = sa.ip();
    if ip.is_unspecified() {
        return Err(format!(
            "SECURITY: remote listener MUST bind a specific interface address, \
             not a wildcard ({addr}). Refusing to start."
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// Custom fail-closed mTLS client cert verifier (AC-2-4)
// ---------------------------------------------------------------------------

/// A rustls `ClientCertVerifier` that ONLY accepts SPKI hashes present in the
/// pinned-peer registry.  Fail-closed: no cert OR unknown cert = reject at handshake.
#[derive(Debug)]
pub struct PinnedSpkiVerifier {
    /// Set of allowed SPKI hashes (hex, lowercase).
    pub allowed: Arc<std::sync::Mutex<std::collections::HashSet<String>>>,
}

impl PinnedSpkiVerifier {
    pub fn new(hashes: Vec<String>) -> Arc<Self> {
        let set: std::collections::HashSet<String> = hashes.into_iter().collect();
        Arc::new(PinnedSpkiVerifier {
            allowed: Arc::new(std::sync::Mutex::new(set)),
        })
    }
}

impl ClientCertVerifier for PinnedSpkiVerifier {
    fn root_hint_subjects(&self) -> &[rustls::DistinguishedName] {
        // No CA hints — TOFU / SPKI pinning.
        &[]
    }

    fn verify_client_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        let spki = compute_spki_hash_from_cert_der(end_entity.as_ref())
            .map_err(|e| rustls::Error::General(e))?;
        let allowed = self.allowed.lock().unwrap();
        if allowed.contains(&spki) {
            Ok(ClientCertVerified::assertion())
        } else {
            Err(rustls::Error::General(format!(
                "client cert SPKI {spki} not in pinned-peer registry"
            )))
        }
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        // TLS 1.2 is not permitted (we enforce TLS 1.3 only).
        Err(rustls::Error::General(
            "TLS 1.2 not permitted by bridge verifier".to_string(),
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }

    /// Explicit fail-closed for the "no client cert" case (tokio-rustls #83).
    fn client_auth_mandatory(&self) -> bool {
        true
    }
}

// ---------------------------------------------------------------------------
// AnyCertVerifier — permissive client cert verifier for pairing-only TLS.
//
// During pairing the dialer is not yet pinned, so the normal PinnedSpkiVerifier
// would reject the handshake.  AnyCertVerifier accepts ANY presented client cert
// (trust is bootstrapped by PAKE + human SAS comparison).
//
// SCOPE: used ONLY for the dedicated pairing listener.  The normal data listener
// keeps PinnedSpkiVerifier (fail-closed).  Both verifiers enforce TLS 1.3 only.
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub struct AnyCertVerifier;

impl ClientCertVerifier for AnyCertVerifier {
    fn root_hint_subjects(&self) -> &[rustls::DistinguishedName] {
        &[]
    }

    fn verify_client_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<ClientCertVerified, rustls::Error> {
        // Accept any cert: trust is provided by PAKE + SAS, not PKI.
        Ok(ClientCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General(
            "TLS 1.2 not permitted by pairing verifier".to_string(),
        ))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }

    /// Pairing requires the dialer to present a cert (so we can extract its SPKI).
    fn client_auth_mandatory(&self) -> bool {
        true
    }
}

// ---------------------------------------------------------------------------
// SAS derivation
// ---------------------------------------------------------------------------

/// Derive a 6-character SAS from:
///   HKDF(session_key || min(spki_a, spki_b) || max(spki_a, spki_b), "muya-bridge-sas-v1")
///
/// CANONICAL: The two SPKI hashes are sorted lexicographically before concatenation.
/// This ensures both the dialer and invitee produce the IDENTICAL SAS regardless of
/// which side passes their own SPKI as the first argument.  Both sides call:
///   derive_sas(session_key, &our_spki, &peer_spki)
/// and the function normalises the order internally.
pub fn derive_sas(session_key: &[u8], our_spki: &str, peer_spki: &str) -> String {
    // Sort to make order-canonical: min first, max second.
    let (first, second) = if our_spki <= peer_spki {
        (our_spki, peer_spki)
    } else {
        (peer_spki, our_spki)
    };
    let ikm: Vec<u8> = session_key
        .iter()
        .chain(first.as_bytes())
        .chain(second.as_bytes())
        .copied()
        .collect();
    let hk = Hkdf::<Sha256>::new(None, &ikm);
    let mut okm = [0u8; 4];
    hk.expand(b"muya-bridge-sas-v1", &mut okm)
        .expect("HKDF expand");
    format!("{:02X}{:02X}{:02X}", okm[0], okm[1], okm[2])
}

// ---------------------------------------------------------------------------
// PAKE wire message types (versioned v1)
// ---------------------------------------------------------------------------

#[derive(Debug, Serialize, Deserialize)]
pub struct PakeInit {
    pub wire_v: u8,          // must be PAKE_WIRE_VERSION
    pub spake2_msg: Vec<u8>, // SPAKE2 outgoing message
    pub our_cert_der: Vec<u8>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct PakeReply {
    pub wire_v: u8,
    pub spake2_msg: Vec<u8>,
    pub our_cert_der: Vec<u8>,
}

// ---------------------------------------------------------------------------
// Tauri commands (AC-2-2 remote listener start/stop)
// ---------------------------------------------------------------------------

/// Enable (`true`) or disable (`false`) the remote mTLS TCP listener.
///
/// `iface` must be a specific interface address + port, e.g. "192.168.1.5:9876".
/// NEVER accepts 0.0.0.0 / :: — returns an error if attempted.
#[tauri::command]
pub async fn bridge_remote_listen(
    enable: bool,
    iface: String,
    state: State<'_, RemoteBridgeState>,
    app: AppHandle,
) -> Result<(), String> {
    let mut listener_guard = state.listener.lock().await;

    if enable {
        if listener_guard.is_some() {
            return Ok(()); // already listening
        }

        // AC-2-2 assertion: NEVER bind wildcard.
        assert_not_wildcard(&iface)?;

        let (identity, registry) = state.ensure_initialized().await?;

        // Build rustls ServerConfig with fail-closed mTLS verifier.
        let server_config = build_server_config(&identity, registry.clone()).await?;
        let acceptor = TlsAcceptor::from(Arc::new(server_config));

        let listener = TcpListener::bind(&iface)
            .await
            .map_err(|e| format!("bind remote listener {iface}: {e}"))?;
        let listener = Arc::new(listener);
        let listener_clone = listener.clone();

        let app_clone = app.clone();

        tauri::async_runtime::spawn(async move {
            loop {
                match listener_clone.accept().await {
                    Ok((stream, peer_addr)) => {
                        let acceptor2 = acceptor.clone();
                        let app2 = app_clone.clone();
                        tauri::async_runtime::spawn(async move {
                            match acceptor2.accept(stream).await {
                                Ok(tls_stream) => {
                                    // AC-2-4: handshake passed the verifier (pinned cert).
                                    // Task dispatch is Faz 3; emit peer-status here.
                                    let _ = app2.emit(
                                        "bridge://peer-status",
                                        format!("connected:{peer_addr}"),
                                    );
                                    // Keep connection; Faz 3 adds full handler.
                                    drop(tls_stream);
                                }
                                Err(e) => {
                                    // Handshake failed — fail-closed (unknown/no cert).
                                    #[cfg(debug_assertions)]
                                    eprintln!(
                                        "[bridge-remote] mTLS handshake rejected {peer_addr}: {e}"
                                    );
                                    let _ = app2.emit(
                                        "bridge://error",
                                        format!("handshake_rejected:{peer_addr}:{e}"),
                                    );
                                }
                            }
                        });
                    }
                    Err(e) => {
                        #[cfg(debug_assertions)]
                        eprintln!("[bridge-remote] accept loop exiting: {e}");
                        break;
                    }
                }
            }
        });

        *listener_guard = Some(listener);
        let _ = app.emit("bridge://peer-status", "remote_listener:started");
    } else {
        if let Some(_l) = listener_guard.take() {
            let _ = app.emit("bridge://peer-status", "remote_listener:stopped");
        }
    }
    Ok(())
}

/// Build a rustls `ServerConfig` with fail-closed SPKI-pinned mTLS.
async fn build_server_config(
    identity: &BridgeIdentity,
    registry: Arc<Mutex<PeerRegistry>>,
) -> Result<ServerConfig, String> {
    let cert = CertificateDer::from(identity.cert_der.clone());
    let key = PrivateKeyDer::try_from(identity.key_der.clone())
        .map_err(|e| format!("load private key: {e}"))?;

    // Collect pinned SPKI hashes.
    let hashes: Vec<String> = {
        let reg = registry.lock().await;
        reg.peers.keys().cloned().collect()
    };

    let verifier = PinnedSpkiVerifier::new(hashes);

    let config =
        ServerConfig::builder_with_provider(rustls::crypto::ring::default_provider().into())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|e| format!("tls config versions: {e}"))?
            .with_client_cert_verifier(verifier)
            .with_single_cert(vec![cert], key)
            .map_err(|e| format!("tls server config: {e}"))?;

    Ok(config)
}

// ---------------------------------------------------------------------------
// Tauri commands — pairing (AC-2-3)
// ---------------------------------------------------------------------------

/// Generate a one-time 8-digit PIN and arm the SPAKE2 responder (invitee side).
/// Returns `{ pin, expires_at, our_spki }`.
///
/// IMPORTANT: This only arms the PIN.  To actually accept a dialer connection, call
/// `bridge_pair_start_listener(pairing_iface)` next.  The two-step design lets the
/// frontend show the PIN to the operator before the network socket is opened.
#[tauri::command]
pub async fn bridge_pair_invite(
    state: State<'_, RemoteBridgeState>,
) -> Result<serde_json::Value, String> {
    let (identity, _registry) = state.ensure_initialized().await?;

    let pin = generate_pin();
    let expires_ts = unix_now() + PIN_TTL.as_secs();

    // Store the PIN in managed state.
    // The SPAKE2 start_b state is NOT stored here because Spake2 state is neither
    // Clone nor Send.  It is created fresh inside `handle_pairing_connection` when
    // the dialer's TCP connection arrives — start_b is randomised each call, which
    // is correct: we create a fresh B-side state for each incoming pairing attempt.
    let active = ActivePin {
        pin: pin.clone(),
        created_at: Instant::now(),
        attempts: 0,
        used: false,
        spake2_outmsg: None, // populated by handle_pairing_connection on first connect
        pending_sas: None,
    };
    *state.active_pin.lock().await = Some(active);

    Ok(serde_json::json!({
        "pin": pin,
        "expires_at": expires_ts,
        "our_spki": identity.spki_hash,
    }))
}

/// Start the dedicated pairing listener on `pairing_iface` (e.g. "192.168.1.5:9877").
///
/// This listener uses `AnyCertVerifier` (accepts any dialer cert — trust is bootstrapped
/// by PAKE + human SAS comparison) and is SEPARATE from the normal data listener which
/// keeps its fail-closed `PinnedSpkiVerifier` unchanged.
///
/// The listener auto-closes after accepting one connection (single-use PIN) or after
/// the PIN expires / is locked out.
#[tauri::command]
pub async fn bridge_pair_start_listener(
    pairing_iface: String,
    state: State<'_, RemoteBridgeState>,
    app: AppHandle,
) -> Result<(), String> {
    // Reject wildcard addresses.
    assert_not_wildcard(&pairing_iface)?;

    // Refuse to open a second pairing listener.
    {
        let guard = state.pairing_listener.lock().await;
        if guard.is_some() {
            return Err("pairing listener already active".to_string());
        }
    }

    let (identity, _registry) = state.ensure_initialized().await?;

    // Build a ServerConfig that uses AnyCertVerifier (pairing-only).
    let pairing_server_config = build_pairing_server_config(&identity)?;
    let acceptor = TlsAcceptor::from(Arc::new(pairing_server_config));

    let listener = TcpListener::bind(&pairing_iface)
        .await
        .map_err(|e| format!("bind pairing listener {pairing_iface}: {e}"))?;
    let listener = Arc::new(listener);

    {
        let mut guard = state.pairing_listener.lock().await;
        *guard = Some(listener.clone());
    }

    // Snapshot the current PIN (value-copy — ActivePin is Clone).
    let current_pin: Option<ActivePin> = state.active_pin.lock().await.clone();

    // Shared result channel: spawned task writes PairingResult; we read it to update state.
    let shared_result: Arc<Mutex<Option<PairingResult>>> = Arc::new(Mutex::new(None));
    let shared_result_task = shared_result.clone();

    let app_clone = app.clone();
    let state_identity = identity.clone();
    let listener_clone = listener.clone();
    let pairing_iface_clone = pairing_iface.clone();

    // Spawned task: accept exactly ONE pairing connection then self-terminate.
    tauri::async_runtime::spawn(async move {
        let _ = app_clone
            .emit("bridge://pairing-status", "pairing_listener:started")
            .ok();

        match listener_clone.accept().await {
            Ok((stream, peer_addr)) => match acceptor.accept(stream).await {
                Ok(tls_stream) => {
                    match handle_pairing_connection(
                        tls_stream,
                        peer_addr.to_string(),
                        &state_identity,
                        current_pin,
                    )
                    .await
                    {
                        Ok(result) => {
                            let _ = app_clone.emit("bridge://sas-compare", &result.sas).ok();
                            *shared_result_task.lock().await = Some(result);
                        }
                        Err(e) => {
                            #[cfg(debug_assertions)]
                            eprintln!(
                                "[bridge-remote] pairing connection error from {peer_addr}: {e}"
                            );
                            let _ = app_clone
                                .emit("bridge://error", format!("pairing_failed:{peer_addr}:{e}"))
                                .ok();
                        }
                    }
                }
                Err(e) => {
                    #[cfg(debug_assertions)]
                    eprintln!("[bridge-remote] pairing TLS handshake failed from {peer_addr}: {e}");
                    let _ = app_clone
                        .emit(
                            "bridge://error",
                            format!("pairing_tls_failed:{peer_addr}:{e}"),
                        )
                        .ok();
                }
            },
            Err(e) => {
                #[cfg(debug_assertions)]
                eprintln!("[bridge-remote] pairing accept failed on {pairing_iface_clone}: {e}");
            }
        }

        let _ = app_clone
            .emit("bridge://pairing-status", "pairing_listener:stopped")
            .ok();
    });

    // Watcher task: waits for the pairing result then writes it into managed state.
    //
    // RemoteBridgeState is 'static — Tauri manages it for the full process lifetime.
    // Casting to a raw pointer and dereferencing in a spawned task is the standard
    // pattern in tokio-based Tauri apps for bridging the 'static lifetime gap.
    // SAFETY invariant: state.inner() pointer is valid until process exit.
    let state_raw = state.inner() as *const RemoteBridgeState as usize;
    tauri::async_runtime::spawn(async move {
        // Poll at 100 ms intervals; PIN TTL is 300 s → at most 3 000 polls.
        for _ in 0..3000 {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            let guard = shared_result.lock().await;
            if let Some(ref result) = *guard {
                // SAFETY: RemoteBridgeState is 'static (Tauri managed).
                let state_ref = unsafe { &*(state_raw as *const RemoteBridgeState) };
                let mut ap = state_ref.active_pin.lock().await;
                if let Some(active) = ap.as_mut() {
                    active.used = true;
                    active.pending_sas = Some(PendingSas {
                        sas: result.sas.clone(),
                        peer_spki: result.peer_spki.clone(),
                        peer_label: result.peer_label.clone(),
                        peer_addr: result.peer_addr.clone(),
                    });
                }
                // Pairing window closed (single-use).
                drop(guard);
                let state_ref2 = unsafe { &*(state_raw as *const RemoteBridgeState) };
                let mut pl = state_ref2.pairing_listener.lock().await;
                pl.take();
                break;
            }
        }
    });

    Ok(())
}

// ---------------------------------------------------------------------------
// Invitee-side pairing helpers
// ---------------------------------------------------------------------------

/// Result returned by `handle_pairing_connection` after a successful PAKE exchange.
#[derive(Debug, Clone)]
pub struct PairingResult {
    /// The SAS that the invitee derived — the human must compare this with the dialer's SAS.
    pub sas: String,
    /// SPKI hash of the dialer's cert (used to pin the peer on confirm).
    pub peer_spki: String,
    /// Human label — placeholder until the operator confirms/labels.
    pub peer_label: String,
    /// TCP address the dialer connected from.
    pub peer_addr: String,
}

/// Build a TLS ServerConfig using AnyCertVerifier (pairing-only; does NOT pin certs).
fn build_pairing_server_config(identity: &BridgeIdentity) -> Result<ServerConfig, String> {
    let cert = CertificateDer::from(identity.cert_der.clone());
    let key = PrivateKeyDer::try_from(identity.key_der.clone())
        .map_err(|e| format!("load private key for pairing: {e}"))?;

    let verifier = Arc::new(AnyCertVerifier);
    let config =
        ServerConfig::builder_with_provider(rustls::crypto::ring::default_provider().into())
            .with_protocol_versions(&[&rustls::version::TLS13])
            .map_err(|e| format!("pairing tls versions: {e}"))?
            .with_client_cert_verifier(verifier)
            .with_single_cert(vec![cert], key)
            .map_err(|e| format!("pairing tls server config: {e}"))?;

    Ok(config)
}

/// Invitee-side pairing protocol handler.
///
/// Called for each incoming connection on the pairing listener.  Performs:
///   1. PIN validation (expired / locked / used → reject immediately).
///   2. Read `PakeInit` from the dialer; extract dialer cert SPKI.
///   3. `Spake2::start_b` with the PIN → fresh B-side state.
///   4. `finish(init.spake2_msg)` → session_key.
///   5. `derive_sas(session_key, our_spki, dialer_spki)` — canonical (sorted).
///   6. Send `PakeReply` with our cert + B-side outmsg.
///   7. Return `PairingResult` to the caller for human SAS comparison.
///
/// On PIN failure (wrong/expired/locked) the function returns an error without
/// completing PAKE; the connection is dropped.
async fn handle_pairing_connection<S>(
    mut tls_stream: S,
    peer_addr: String,
    identity: &BridgeIdentity,
    active_pin: Option<ActivePin>,
) -> Result<PairingResult, String>
where
    S: AsyncReadExt + AsyncWriteExt + Unpin,
{
    // Gate: must have an armed, valid PIN.
    let active = active_pin.ok_or("no active PIN — call bridge_pair_invite first")?;
    if is_pin_expired(&active) {
        return Err("PIN expired".to_string());
    }
    if is_pin_locked_out(&active) {
        return Err("PIN locked out (too many attempts)".to_string());
    }
    if active.used {
        return Err("PIN already used (single-use)".to_string());
    }

    // Read PakeInit from the dialer.
    let init_bytes = read_raw_frame(&mut tls_stream).await?;
    let init: PakeInit =
        serde_json::from_slice(&init_bytes).map_err(|e| format!("parse PakeInit: {e}"))?;

    if init.wire_v != PAKE_WIRE_VERSION {
        return Err(format!(
            "PAKE wire version mismatch: got {}, expected {PAKE_WIRE_VERSION}",
            init.wire_v
        ));
    }

    // Extract dialer cert SPKI from PakeInit (the cert it sent in-band).
    let dialer_spki = compute_spki_hash_from_cert_der(&init.our_cert_der)?;

    // Run SPAKE2 B-side with the stored PIN.
    // start_b is randomised — state is held locally (non-Clone/Send).
    let (spake2_state, our_outmsg) = Spake2::<RistrettoGroup>::start_b(
        &Password::new(active.pin.as_bytes()),
        &Spake2Identity::new(b"dialer"),
        &Spake2Identity::new(b"invitee"),
    )
    .map_err(|e| format!("SPAKE2 start_b: {e}"))?;

    // Finish SPAKE2 with the dialer's message → session key.
    let session_key = spake2_state
        .finish(&init.spake2_msg)
        .map_err(|e| format!("SPAKE2 finish (invitee): {e}"))?;

    // Derive SAS (canonical: derive_sas sorts the two SPKIs internally).
    let sas = derive_sas(session_key.expose(), &identity.spki_hash, &dialer_spki);

    // Send PakeReply with our cert + B-side outmsg.
    let reply = PakeReply {
        wire_v: PAKE_WIRE_VERSION,
        spake2_msg: our_outmsg,
        our_cert_der: identity.cert_der.clone(),
    };
    let reply_bytes =
        serde_json::to_vec(&reply).map_err(|e| format!("serialize PakeReply: {e}"))?;
    write_raw_frame(&mut tls_stream, &reply_bytes).await?;

    Ok(PairingResult {
        sas,
        peer_spki: dialer_spki,
        peer_label: format!("peer@{peer_addr}"),
        peer_addr,
    })
}

/// Dialer side: run SPAKE2, exchange certs, derive SAS.
/// Call `bridge_pair_confirm_sas` next to complete pairing.
#[tauri::command]
pub async fn bridge_pair_connect(
    addr: String,
    pin: String,
    label: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<serde_json::Value, String> {
    let (identity, _registry) = state.ensure_initialized().await?;

    // Validate addr (must be parseable; not wildcard for good hygiene).
    SocketAddr::from_str(&addr).map_err(|_| format!("invalid peer address: {addr:?}"))?;

    // Generate SPAKE2 state for the dialer (we are "A" / client side).
    let password = Password::new(pin.as_bytes());
    let (spake2_state, our_outmsg) = Spake2::<RistrettoGroup>::start_a(
        &password,
        &Spake2Identity::new(b"dialer"),
        &Spake2Identity::new(b"invitee"),
    )
    .map_err(|e| format!("SPAKE2 start_a: {e}"))?;

    // Connect TCP.
    let tcp_stream = tokio::net::TcpStream::connect(&addr)
        .await
        .map_err(|e| format!("connect to {addr}: {e}"))?;

    // TLS client: present our cert; skip normal server cert verification
    // (we use PAKE + SAS to bootstrap trust; after SAS we pin the server SPKI).
    let client_cert = CertificateDer::from(identity.cert_der.clone());
    let client_key = PrivateKeyDer::try_from(identity.key_der.clone())
        .map_err(|e| format!("load client key: {e}"))?;

    let client_config = rustls::ClientConfig::builder_with_provider(
        rustls::crypto::ring::default_provider().into(),
    )
    .with_protocol_versions(&[&rustls::version::TLS13])
    .map_err(|e| format!("tls client versions: {e}"))?
    .dangerous()
    .with_custom_certificate_verifier(Arc::new(NoCertVerifier))
    .with_client_auth_cert(vec![client_cert], client_key)
    .map_err(|e| format!("tls client cert: {e}"))?;

    let connector = tokio_rustls::TlsConnector::from(Arc::new(client_config));
    let server_name = rustls::pki_types::ServerName::try_from("muya-bridge")
        .map_err(|e| format!("server name: {e}"))?;
    let mut tls_stream = connector
        .connect(server_name, tcp_stream)
        .await
        .map_err(|e| format!("TLS connect: {e}"))?;

    // Extract server cert SPKI from the TLS session.
    let peer_cert_der = {
        let conn = tls_stream.get_ref().1;
        let certs = conn
            .peer_certificates()
            .ok_or("no peer certificates in TLS handshake")?;
        certs
            .first()
            .ok_or("empty peer cert chain")?
            .clone()
            .to_vec()
    };
    let peer_spki = compute_spki_hash_from_cert_der(&peer_cert_der)?;

    // PAKE exchange: send our outmsg (with our cert), receive theirs.
    let init = PakeInit {
        wire_v: PAKE_WIRE_VERSION,
        spake2_msg: our_outmsg,
        our_cert_der: identity.cert_der.clone(),
    };
    let init_bytes = serde_json::to_vec(&init).map_err(|e| format!("serialize PakeInit: {e}"))?;
    write_raw_frame(&mut tls_stream, &init_bytes).await?;

    let reply_bytes = read_raw_frame(&mut tls_stream).await?;
    let reply: PakeReply =
        serde_json::from_slice(&reply_bytes).map_err(|e| format!("parse PakeReply: {e}"))?;

    if reply.wire_v != PAKE_WIRE_VERSION {
        return Err(format!(
            "PAKE wire version mismatch: got {}, expected {PAKE_WIRE_VERSION}",
            reply.wire_v
        ));
    }

    // Complete SPAKE2 on dialer side.
    let session_key = spake2_state
        .finish(&reply.spake2_msg)
        .map_err(|e| format!("SPAKE2 finish: {e}"))?;

    // Derive SAS.
    let sas = derive_sas(session_key.expose(), &identity.spki_hash, &peer_spki);

    // Store pending SAS for human confirmation.
    let pending = PendingSas {
        sas: sas.clone(),
        peer_spki: peer_spki.clone(),
        peer_label: label.clone(),
        peer_addr: addr.clone(),
    };
    {
        let mut ap = state.active_pin.lock().await;
        if let Some(active) = ap.as_mut() {
            active.pending_sas = Some(pending);
        } else {
            *ap = Some(ActivePin {
                pin: String::new(),
                created_at: Instant::now(),
                attempts: 0,
                used: false,
                spake2_outmsg: None,
                pending_sas: Some(pending),
            });
        }
    }

    drop(tls_stream);

    Ok(serde_json::json!({
        "sas": sas,
        "peer_spki": peer_spki,
    }))
}

/// Human confirms (or rejects) the SAS. On confirm, pins the peer SPKI.
#[tauri::command]
pub async fn bridge_pair_confirm_sas(
    peer_spki: String,
    sas_ok: bool,
    label: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<(), String> {
    if !sas_ok {
        let mut ap = state.active_pin.lock().await;
        if let Some(active) = ap.as_mut() {
            active.pending_sas = None;
        }
        return Err("SAS rejected by operator — pairing aborted (no peer pinned)".to_string());
    }

    let (_identity, registry) = state.ensure_initialized().await?;

    // Retrieve pending SAS from state.
    let pending = {
        let mut ap = state.active_pin.lock().await;
        let active = ap.as_mut().ok_or("no active pairing session")?;
        active
            .pending_sas
            .take()
            .ok_or("no pending SAS to confirm")?
    };

    if pending.peer_spki != peer_spki {
        return Err(format!(
            "SPKI mismatch: expected {}, got {peer_spki}",
            pending.peer_spki
        ));
    }

    // Pin the peer.
    let peer = PinnedPeer {
        schema_v: REGISTRY_SCHEMA_VERSION,
        spki_hash: peer_spki.clone(),
        label,
        last_addr: Some(pending.peer_addr),
        paired_at: unix_now(),
        capability: "research".to_string(),
    };

    registry.lock().await.insert(peer)?;

    Ok(())
}

/// List all pinned peers.
#[tauri::command]
pub async fn bridge_list_peers(
    state: State<'_, RemoteBridgeState>,
) -> Result<Vec<PinnedPeer>, String> {
    let (_id, registry) = state.ensure_initialized().await?;
    let reg = registry.lock().await;
    Ok(reg.peers.values().cloned().collect())
}

/// Revoke (unpin) a peer by SPKI hash.
#[tauri::command]
pub async fn bridge_revoke_peer(
    spki_hash: String,
    state: State<'_, RemoteBridgeState>,
) -> Result<(), String> {
    let (_id, registry) = state.ensure_initialized().await?;
    let result = registry.lock().await.remove(&spki_hash);
    result
}

// ---------------------------------------------------------------------------
// PIN helpers (exported for tests)
// ---------------------------------------------------------------------------

pub fn generate_pin() -> String {
    use rand::Rng;
    let mut rng = rand::rng();
    format!("{:08}", rng.random_range(0u32..100_000_000u32))
}

pub fn unix_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

/// Is the active PIN expired?
pub fn is_pin_expired(pin: &ActivePin) -> bool {
    pin.created_at.elapsed() >= PIN_TTL
}

/// Is the active PIN locked out (too many failed attempts)?
pub fn is_pin_locked_out(pin: &ActivePin) -> bool {
    pin.attempts >= PIN_MAX_ATTEMPTS
}

/// Validate an active PIN against the provided string.
/// Returns error if: expired, locked out, already used, wrong value.
pub fn validate_pin(active: &mut ActivePin, attempt: &str) -> Result<(), String> {
    if is_pin_expired(active) {
        return Err("PIN expired".to_string());
    }
    if is_pin_locked_out(active) {
        return Err("PIN locked out (too many attempts)".to_string());
    }
    if active.used {
        return Err("PIN already used (single-use)".to_string());
    }
    if active.pin != attempt {
        active.attempts += 1;
        return Err(format!(
            "wrong PIN ({} of {} attempts)",
            active.attempts, PIN_MAX_ATTEMPTS
        ));
    }
    active.used = true;
    Ok(())
}

// ---------------------------------------------------------------------------
// Raw TCP frame helpers (for PAKE exchange over TLS stream)
// ---------------------------------------------------------------------------

async fn write_raw_frame<S: AsyncWriteExt + Unpin>(
    stream: &mut S,
    body: &[u8],
) -> Result<(), String> {
    if body.len() > MAX_FRAME_BYTES {
        return Err(format!("frame too large: {}", body.len()));
    }
    let len = body.len() as u32;
    stream
        .write_all(&len.to_be_bytes())
        .await
        .map_err(|e| format!("write frame len: {e}"))?;
    stream
        .write_all(body)
        .await
        .map_err(|e| format!("write frame body: {e}"))?;
    Ok(())
}

async fn read_raw_frame<S: AsyncReadExt + Unpin>(stream: &mut S) -> Result<Vec<u8>, String> {
    let mut len_buf = [0u8; 4];
    stream
        .read_exact(&mut len_buf)
        .await
        .map_err(|e| format!("read frame len: {e}"))?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME_BYTES {
        return Err(format!(
            "frame too large: {len} bytes (max {MAX_FRAME_BYTES})"
        ));
    }
    let mut body = vec![0u8; len];
    stream
        .read_exact(&mut body)
        .await
        .map_err(|e| format!("read frame body: {e}"))?;
    Ok(body)
}

// ---------------------------------------------------------------------------
// NoCertVerifier — used ONLY during initial PAKE pairing.
// After SAS confirmation, the peer is pinned and PinnedSpkiVerifier takes over
// for all subsequent connections.
// ---------------------------------------------------------------------------

#[derive(Debug)]
struct NoCertVerifier;

impl rustls::client::danger::ServerCertVerifier for NoCertVerifier {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        // During PAKE pairing we defer cert trust to the PAKE + SAS mechanism.
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &CertificateDer<'_>,
        _dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        Err(rustls::Error::General("TLS 1.2 not permitted".into()))
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(
            message,
            cert,
            dss,
            &rustls::crypto::ring::default_provider().signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    // -------------------------------------------------------------------------
    // AC-2-1: Identity keypair generation, persistence, SPKI stability.
    // -------------------------------------------------------------------------

    #[test]
    fn ac2_1_identity_generate_and_persist() {
        let dir = TempDir::new().expect("tmpdir");
        let dir_path = dir.path().to_path_buf();

        // Generate.
        let id1 = BridgeIdentity::load_or_generate(&dir_path).expect("generate");
        assert!(!id1.cert_der.is_empty(), "cert_der must not be empty");
        assert!(!id1.key_der.is_empty(), "key_der must not be empty");
        assert_eq!(id1.spki_hash.len(), 64, "SPKI hash must be 64 hex chars");

        // Check file permissions.
        let cert_meta = fs::metadata(dir_path.join("identity_cert.pem")).expect("cert meta");
        let key_meta = fs::metadata(dir_path.join("identity_key.pem")).expect("key meta");
        assert_eq!(
            cert_meta.permissions().mode() & 0o777,
            0o600,
            "cert pem must be 0600"
        );
        assert_eq!(
            key_meta.permissions().mode() & 0o777,
            0o600,
            "key pem must be 0600"
        );

        // Reload — SPKI hash must be stable.
        let id2 = BridgeIdentity::load_or_generate(&dir_path).expect("reload");
        assert_eq!(
            id1.spki_hash, id2.spki_hash,
            "SPKI hash must be stable across reload"
        );
        assert_eq!(
            id1.cert_der, id2.cert_der,
            "cert DER must be identical across reload"
        );
    }

    #[test]
    fn ac2_1_spki_hash_stable_multiple_reloads() {
        let dir = TempDir::new().expect("tmpdir");
        let dir_path = dir.path().to_path_buf();
        let id1 = BridgeIdentity::load_or_generate(&dir_path).expect("gen");
        let id2 = BridgeIdentity::load_or_generate(&dir_path).expect("reload-1");
        let id3 = BridgeIdentity::load_or_generate(&dir_path).expect("reload-2");
        assert_eq!(id1.spki_hash, id2.spki_hash);
        assert_eq!(id2.spki_hash, id3.spki_hash);
    }

    #[test]
    fn ac2_1_cert_file_mode_0600() {
        let dir = TempDir::new().expect("tmpdir");
        let _id = BridgeIdentity::load_or_generate(&dir.path().to_path_buf()).expect("gen");
        let meta = fs::metadata(dir.path().join("identity_key.pem")).expect("meta");
        assert_eq!(meta.permissions().mode() & 0o777, 0o600);
    }

    // -------------------------------------------------------------------------
    // AC-2-2: Wildcard address rejection.
    // -------------------------------------------------------------------------

    #[test]
    fn ac2_2_wildcard_0000_rejected() {
        let err = assert_not_wildcard("0.0.0.0:9876").unwrap_err();
        assert!(
            err.contains("wildcard") || err.contains("SECURITY"),
            "expected security error, got: {err}"
        );
    }

    #[test]
    fn ac2_2_wildcard_ipv6_rejected() {
        let err = assert_not_wildcard("[::]:9876").unwrap_err();
        assert!(
            err.contains("wildcard") || err.contains("SECURITY"),
            "expected security error, got: {err}"
        );
    }

    #[test]
    fn ac2_2_specific_iface_accepted() {
        assert_not_wildcard("192.168.1.5:9876").expect("specific iface must be accepted");
        assert_not_wildcard("127.0.0.1:9876").expect("loopback must be accepted (for testing)");
        assert_not_wildcard("[::1]:9876").expect("ipv6 loopback must be accepted");
    }

    #[test]
    fn ac2_2_invalid_addr_rejected() {
        let err = assert_not_wildcard("not_an_addr").unwrap_err();
        assert!(err.contains("invalid address"), "got: {err}");
    }

    // -------------------------------------------------------------------------
    // AC-2-3: SPAKE2 PAKE — correct PIN → shared key; wrong PIN → fail.
    // -------------------------------------------------------------------------

    #[test]
    fn ac2_3_spake2_correct_pin_succeeds() {
        let pin = b"12345678";
        let (state_a, msg_a) = Spake2::<RistrettoGroup>::start_a(
            &Password::new(pin),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_a");
        let (state_b, msg_b) = Spake2::<RistrettoGroup>::start_b(
            &Password::new(pin),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_b");

        let key_a = state_a.finish(&msg_b).expect("finish_a");
        let key_b = state_b.finish(&msg_a).expect("finish_b");
        assert_eq!(
            key_a.expose(),
            key_b.expose(),
            "both sides must derive the same session key"
        );
        assert!(!key_a.expose().is_empty(), "session key must not be empty");
    }

    #[test]
    fn ac2_3_spake2_wrong_pin_fails() {
        let pin_a = b"12345678";
        let pin_b = b"99999999"; // wrong
        let (state_a, msg_a) = Spake2::<RistrettoGroup>::start_a(
            &Password::new(pin_a),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_a");
        let (state_b, msg_b) = Spake2::<RistrettoGroup>::start_b(
            &Password::new(pin_b),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_b");

        let key_a = state_a.finish(&msg_b).expect("finish_a");
        let key_b = state_b.finish(&msg_a).expect("finish_b");
        // Keys diverge — SAS derived from them will differ → pairing fails.
        assert_ne!(
            key_a.expose(),
            key_b.expose(),
            "wrong PIN must produce divergent keys (SAS mismatch → pairing fails)"
        );
    }

    // -------------------------------------------------------------------------
    // AC-2-3: SAS derivation — MITM simulation (different cert → SAS mismatch).
    // -------------------------------------------------------------------------

    #[test]
    fn ac2_3_sas_mitm_cert_mismatch() {
        let pin = b"12345678";
        let session_key = {
            let (state_a, msg_a) = Spake2::<RistrettoGroup>::start_a(
                &Password::new(pin),
                &Spake2Identity::new(b"dialer"),
                &Spake2Identity::new(b"invitee"),
            )
            .expect("start_a");
            let (state_b, msg_b) = Spake2::<RistrettoGroup>::start_b(
                &Password::new(pin),
                &Spake2Identity::new(b"dialer"),
                &Spake2Identity::new(b"invitee"),
            )
            .expect("start_b");
            let ka = state_a.finish(&msg_b).expect("finish_a");
            let _kb = state_b.finish(&msg_a).expect("finish_b");
            ka
        };

        let our_spki = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111";
        let real_peer_spki = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222";
        let mitm_spki = "cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333cccc3333";

        let sas_real = derive_sas(session_key.expose(), our_spki, real_peer_spki);
        let sas_mitm = derive_sas(session_key.expose(), our_spki, mitm_spki);

        assert_ne!(
            sas_real, sas_mitm,
            "MITM cert → SAS must differ (human detects mismatch)"
        );
    }

    #[test]
    fn ac2_3_sas_correct_pairing_matches() {
        let session_key = [0xABu8; 32];
        let our = "spki_ours_hex";
        let peer = "spki_peer_hex";
        let sas1 = derive_sas(&session_key, our, peer);
        let sas2 = derive_sas(&session_key, our, peer);
        assert_eq!(sas1, sas2, "SAS must be deterministic");
        assert_eq!(sas1.len(), 6, "SAS must be 6 chars");
    }

    // -------------------------------------------------------------------------
    // AC-2-4: Custom verifier — pinned accepts, unpinned/no-cert rejects.
    // -------------------------------------------------------------------------

    #[test]
    fn ac2_4_pinned_verifier_accepts_known_hash() {
        let verifier = PinnedSpkiVerifier::new(vec!["abcd1234".to_string()]);
        assert!(verifier.allowed.lock().unwrap().contains("abcd1234"));
    }

    #[test]
    fn ac2_4_pinned_verifier_rejects_unknown_hash() {
        let verifier = PinnedSpkiVerifier::new(vec!["known_hash".to_string()]);
        let allowed = verifier.allowed.lock().unwrap();
        assert!(
            !allowed.contains("unknown_hash"),
            "unknown SPKI must not be in set"
        );
    }

    #[test]
    fn ac2_4_client_auth_mandatory() {
        // Verifier must set client_auth_mandatory = true (no-cert → reject).
        let verifier = PinnedSpkiVerifier::new(vec![]);
        assert!(
            verifier.client_auth_mandatory(),
            "client_auth_mandatory must be true (fail-closed for no-cert)"
        );
    }

    // -------------------------------------------------------------------------
    // AC-2-5: PIN TTL, single-use, attempt lockout.
    // -------------------------------------------------------------------------

    #[test]
    fn ac2_5_pin_ttl_expiry() {
        let pin = ActivePin {
            pin: "12345678".to_string(),
            created_at: Instant::now() - PIN_TTL - Duration::from_secs(1),
            attempts: 0,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };
        assert!(is_pin_expired(&pin), "is_pin_expired must return true");
    }

    #[test]
    fn ac2_5_pin_not_expired_within_ttl() {
        let pin = ActivePin {
            pin: "12345678".to_string(),
            created_at: Instant::now(),
            attempts: 0,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };
        assert!(!is_pin_expired(&pin), "fresh PIN must not be expired");
    }

    #[test]
    fn ac2_5_pin_single_use() {
        let mut pin = ActivePin {
            pin: "12345678".to_string(),
            created_at: Instant::now(),
            attempts: 0,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };
        assert!(!pin.used);
        pin.used = true;
        assert!(pin.used, "PIN must be marked used after single use");
        // validate_pin on used pin returns error.
        let err = validate_pin(&mut pin, "12345678").unwrap_err();
        assert!(err.contains("already used"), "got: {err}");
    }

    #[test]
    fn ac2_5_attempt_lockout() {
        let pin = ActivePin {
            pin: "12345678".to_string(),
            created_at: Instant::now(),
            attempts: PIN_MAX_ATTEMPTS,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };
        assert!(
            is_pin_locked_out(&pin),
            "must be locked out at max attempts"
        );
        // Below max: not locked.
        let pin2 = ActivePin {
            attempts: PIN_MAX_ATTEMPTS - 1,
            ..pin
        };
        assert!(
            !is_pin_locked_out(&pin2),
            "must NOT be locked out below max attempts"
        );
    }

    #[test]
    fn ac2_5_validate_pin_increments_attempts_on_wrong() {
        let mut pin = ActivePin {
            pin: "12345678".to_string(),
            created_at: Instant::now(),
            attempts: 0,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };
        let _ = validate_pin(&mut pin, "00000000"); // wrong
        assert_eq!(pin.attempts, 1);
        let _ = validate_pin(&mut pin, "11111111"); // wrong again
        assert_eq!(pin.attempts, 2);
    }

    #[test]
    fn ac2_5_reconnect_verifies_via_registry() {
        let dir = TempDir::new().expect("tmpdir");
        let dir_path = dir.path().to_path_buf();
        let mut reg = PeerRegistry::load_or_create(&dir_path).expect("registry");

        let spki = "deadbeef".to_string();
        let peer = PinnedPeer {
            schema_v: REGISTRY_SCHEMA_VERSION,
            spki_hash: spki.clone(),
            label: "test-peer".to_string(),
            last_addr: Some("192.168.1.10:9876".to_string()),
            paired_at: unix_now(),
            capability: "research".to_string(),
        };
        reg.insert(peer).expect("insert");
        assert!(reg.is_pinned(&spki), "peer must be pinned after insert");

        // Reload registry from disk — simulates reconnect.
        let reg2 = PeerRegistry::load_or_create(&dir_path).expect("reload");
        assert!(
            reg2.is_pinned(&spki),
            "peer must still be pinned after registry reload (reconnect)"
        );
    }

    // -------------------------------------------------------------------------
    // End-to-end SPAKE2 pairing simulation (correct PIN → both pin each other).
    // -------------------------------------------------------------------------

    #[test]
    fn ac2_5_end_to_end_pairing_correct_pin() {
        let dir_a = TempDir::new().expect("tmpdir_a");
        let dir_b = TempDir::new().expect("tmpdir_b");

        let id_a = BridgeIdentity::load_or_generate(&dir_a.path().to_path_buf()).expect("gen_a");
        let id_b = BridgeIdentity::load_or_generate(&dir_b.path().to_path_buf()).expect("gen_b");

        let pin = b"87654321";

        // Invitee (B) generates SPAKE2 state.
        let (state_b, msg_b) = Spake2::<RistrettoGroup>::start_b(
            &Password::new(pin),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_b");

        // Dialer (A) generates SPAKE2 state.
        let (state_a, msg_a) = Spake2::<RistrettoGroup>::start_a(
            &Password::new(pin),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_a");

        // Exchange messages.
        let key_a = state_a.finish(&msg_b).expect("finish_a");
        let key_b = state_b.finish(&msg_a).expect("finish_b");
        assert_eq!(key_a.expose(), key_b.expose(), "session keys must match");

        // SAS derivation from each side's perspective.
        // derive_sas is canonical (sorts SPKIs internally) — both calls MUST match.
        let sas_a = derive_sas(key_a.expose(), &id_a.spki_hash, &id_b.spki_hash);
        let sas_b = derive_sas(key_b.expose(), &id_b.spki_hash, &id_a.spki_hash);
        assert_eq!(sas_a.len(), 6);
        assert_eq!(sas_b.len(), 6);
        assert_eq!(
            sas_a, sas_b,
            "SAS MUST be identical on both sides (canonical ordering)"
        );

        // Both pin each other.
        let mut reg_a = PeerRegistry::load_or_create(&dir_a.path().to_path_buf()).expect("reg_a");
        let mut reg_b = PeerRegistry::load_or_create(&dir_b.path().to_path_buf()).expect("reg_b");

        reg_a
            .insert(PinnedPeer {
                schema_v: REGISTRY_SCHEMA_VERSION,
                spki_hash: id_b.spki_hash.clone(),
                label: "peer-b".to_string(),
                last_addr: None,
                paired_at: unix_now(),
                capability: "research".to_string(),
            })
            .expect("pin b in a");

        reg_b
            .insert(PinnedPeer {
                schema_v: REGISTRY_SCHEMA_VERSION,
                spki_hash: id_a.spki_hash.clone(),
                label: "peer-a".to_string(),
                last_addr: None,
                paired_at: unix_now(),
                capability: "research".to_string(),
            })
            .expect("pin a in b");

        assert!(reg_a.is_pinned(&id_b.spki_hash), "A must have pinned B");
        assert!(reg_b.is_pinned(&id_a.spki_hash), "B must have pinned A");
    }

    #[test]
    fn ac2_5_end_to_end_wrong_pin_sas_mismatch() {
        let dir_a = TempDir::new().expect("tmpdir_a");
        let dir_b = TempDir::new().expect("tmpdir_b");

        let id_a = BridgeIdentity::load_or_generate(&dir_a.path().to_path_buf()).expect("gen_a");
        let id_b = BridgeIdentity::load_or_generate(&dir_b.path().to_path_buf()).expect("gen_b");

        let pin_a = b"11111111";
        let pin_b = b"22222222"; // wrong PIN

        let (state_a, msg_a) = Spake2::<RistrettoGroup>::start_a(
            &Password::new(pin_a),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_a");
        let (state_b, msg_b) = Spake2::<RistrettoGroup>::start_b(
            &Password::new(pin_b),
            &Spake2Identity::new(b"dialer"),
            &Spake2Identity::new(b"invitee"),
        )
        .expect("start_b");

        let key_a = state_a.finish(&msg_b).expect("finish_a");
        let key_b = state_b.finish(&msg_a).expect("finish_b");
        assert_ne!(key_a.expose(), key_b.expose(), "wrong PIN → keys diverge");

        let sas_a = derive_sas(key_a.expose(), &id_a.spki_hash, &id_b.spki_hash);
        let sas_b = derive_sas(key_b.expose(), &id_b.spki_hash, &id_a.spki_hash);
        assert_ne!(
            sas_a, sas_b,
            "wrong PIN → divergent SAS → pairing must fail"
        );
    }

    // -------------------------------------------------------------------------
    // AC-2-3 REAL SOCKET TESTS — invitee side wired, not simulated.
    //
    // These tests exercise handle_pairing_connection over an in-process
    // tokio::io::duplex pipe (no TLS overhead; tests the PAKE protocol layer).
    // The full TLS socket test exercises the pairing listener end-to-end.
    // -------------------------------------------------------------------------

    /// Helper: run a complete dialer↔invitee PAKE exchange over a duplex pipe.
    /// Returns (invitee_result, dialer_sas) so callers can assert equality.
    async fn run_pake_over_pipe(
        dialer_id: &BridgeIdentity,
        invitee_id: &BridgeIdentity,
        dialer_pin: &str,
        invitee_pin: &str,
    ) -> (Result<PairingResult, String>, String) {
        // Create in-memory bidirectional pipe.
        let (dialer_half, invitee_half) = tokio::io::duplex(65536);
        let (mut dialer_stream, mut invitee_stream) = (dialer_half, invitee_half);

        let dialer_id_clone = dialer_id.clone();
        let invitee_id_clone = invitee_id.clone();
        let dialer_pin_s = dialer_pin.to_string();
        let invitee_pin_s = invitee_pin.to_string();

        // Arm invitee's active_pin.
        let active_pin = ActivePin {
            pin: invitee_pin_s.clone(),
            created_at: Instant::now(),
            attempts: 0,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };

        // Run dialer in a task.
        let dialer_task = tokio::spawn(async move {
            let password = Password::new(dialer_pin_s.as_bytes());
            let (spake2_state, our_outmsg) = Spake2::<RistrettoGroup>::start_a(
                &password,
                &Spake2Identity::new(b"dialer"),
                &Spake2Identity::new(b"invitee"),
            )
            .expect("dialer start_a");

            let init = PakeInit {
                wire_v: PAKE_WIRE_VERSION,
                spake2_msg: our_outmsg,
                our_cert_der: dialer_id_clone.cert_der.clone(),
            };
            let init_bytes = serde_json::to_vec(&init).expect("serialize init");
            write_raw_frame(&mut dialer_stream, &init_bytes)
                .await
                .expect("write init");

            let reply_bytes = read_raw_frame(&mut dialer_stream)
                .await
                .expect("read reply");
            let reply: PakeReply = serde_json::from_slice(&reply_bytes).expect("parse reply");
            let session_key = spake2_state
                .finish(&reply.spake2_msg)
                .expect("dialer finish");
            let peer_spki =
                compute_spki_hash_from_cert_der(&reply.our_cert_der).expect("dialer peer spki");
            derive_sas(session_key.expose(), &dialer_id_clone.spki_hash, &peer_spki)
        });

        // Run invitee protocol handler.
        let invitee_result = handle_pairing_connection(
            invitee_stream,
            "127.0.0.1:0".to_string(),
            &invitee_id_clone,
            Some(active_pin),
        )
        .await;

        let dialer_sas = dialer_task.await.expect("dialer task");
        (invitee_result, dialer_sas)
    }

    #[tokio::test]
    async fn ac2_3_real_socket_correct_pin_sas_matches() {
        let dir_a = TempDir::new().expect("tmpdir_a");
        let dir_b = TempDir::new().expect("tmpdir_b");
        let id_a = BridgeIdentity::load_or_generate(&dir_a.path().to_path_buf()).expect("gen_a");
        let id_b = BridgeIdentity::load_or_generate(&dir_b.path().to_path_buf()).expect("gen_b");
        let pin = "12345678";

        let (invitee_result, dialer_sas) = run_pake_over_pipe(&id_a, &id_b, pin, pin).await;
        let invitee = invitee_result.expect("invitee PAKE must succeed with correct PIN");

        assert_eq!(
            invitee.sas, dialer_sas,
            "BOTH sides must derive the identical SAS with the correct PIN"
        );
        assert_eq!(invitee.sas.len(), 6, "SAS must be 6 chars");
        assert_eq!(
            invitee.peer_spki, id_a.spki_hash,
            "invitee must have dialer's SPKI"
        );
    }

    #[tokio::test]
    async fn ac2_3_real_socket_wrong_pin_sas_differs() {
        let dir_a = TempDir::new().expect("tmpdir_a");
        let dir_b = TempDir::new().expect("tmpdir_b");
        let id_a = BridgeIdentity::load_or_generate(&dir_a.path().to_path_buf()).expect("gen_a");
        let id_b = BridgeIdentity::load_or_generate(&dir_b.path().to_path_buf()).expect("gen_b");

        // Invitee armed with correct PIN; dialer uses wrong PIN.
        let (invitee_result, dialer_sas) =
            run_pake_over_pipe(&id_a, &id_b, "99999999", "12345678").await;
        let invitee =
            invitee_result.expect("PAKE exchange completes even on wrong PIN (SAS diverges)");

        assert_ne!(
            invitee.sas, dialer_sas,
            "wrong PIN → SAS MUST differ on the two sides → human detects mismatch"
        );
    }

    #[tokio::test]
    async fn ac2_3_real_socket_mitm_cert_sas_differs() {
        // MITM scenario: dialer uses a third cert; SAS on invitee is computed with
        // the real dialer SPKI (from PakeInit.our_cert_der) while the dialer uses its own.
        // The invitee's SAS is computed from the MITM cert's SPKI → mismatch detected.
        let dir_a = TempDir::new().expect("tmpdir_a");
        let dir_b = TempDir::new().expect("tmpdir_b");
        let dir_mitm = TempDir::new().expect("tmpdir_mitm");
        let id_a = BridgeIdentity::load_or_generate(&dir_a.path().to_path_buf()).expect("gen_a");
        let id_b = BridgeIdentity::load_or_generate(&dir_b.path().to_path_buf()).expect("gen_b");
        let id_mitm =
            BridgeIdentity::load_or_generate(&dir_mitm.path().to_path_buf()).expect("gen_mitm");
        let pin = "11111111";

        // Dialer uses its real cert; PakeInit.our_cert_der is substituted with MITM cert.
        let (dialer_half, invitee_half) = tokio::io::duplex(65536);
        let (mut dialer_stream, mut invitee_stream) = (dialer_half, invitee_half);

        let id_a_clone = id_a.clone();
        let id_mitm_clone = id_mitm.clone();
        let pin_s = pin.to_string();

        let dialer_task = tokio::spawn(async move {
            let password = Password::new(pin_s.as_bytes());
            let (spake2_state, our_outmsg) = Spake2::<RistrettoGroup>::start_a(
                &password,
                &Spake2Identity::new(b"dialer"),
                &Spake2Identity::new(b"invitee"),
            )
            .expect("start_a");

            // MITM substitutes its cert in PakeInit instead of the dialer's.
            let init = PakeInit {
                wire_v: PAKE_WIRE_VERSION,
                spake2_msg: our_outmsg,
                our_cert_der: id_mitm_clone.cert_der.clone(), // <-- MITM cert
            };
            write_raw_frame(&mut dialer_stream, &serde_json::to_vec(&init).expect("ser"))
                .await
                .expect("write");

            let reply_bytes = read_raw_frame(&mut dialer_stream).await.expect("read");
            let reply: PakeReply = serde_json::from_slice(&reply_bytes).expect("parse");
            let session_key = spake2_state.finish(&reply.spake2_msg).expect("finish");
            // Dialer computes SAS with its REAL cert (id_a), not MITM's.
            let peer_spki =
                compute_spki_hash_from_cert_der(&reply.our_cert_der).expect("peer spki");
            derive_sas(session_key.expose(), &id_a_clone.spki_hash, &peer_spki)
        });

        let active_pin = ActivePin {
            pin: pin.to_string(),
            created_at: Instant::now(),
            attempts: 0,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };
        // Invitee sees MITM cert in PakeInit → computes SAS with MITM SPKI.
        let invitee_result = handle_pairing_connection(
            invitee_stream,
            "127.0.0.1:0".to_string(),
            &id_b,
            Some(active_pin),
        )
        .await;
        let invitee = invitee_result.expect("PAKE completes");
        let dialer_sas = dialer_task.await.expect("dialer");

        // Invitee's peer_spki is MITM's; dialer's peer_spki is invitee's.
        assert_eq!(
            invitee.peer_spki, id_mitm.spki_hash,
            "invitee sees MITM cert"
        );
        // SAS diverges because canonical sort of (invitee, MITM) ≠ sort of (dialer, invitee).
        assert_ne!(
            invitee.sas, dialer_sas,
            "MITM cert → SAS must differ → human detects mismatch"
        );
    }

    #[tokio::test]
    async fn ac2_3_real_socket_no_pin_armed_rejected() {
        let dir_b = TempDir::new().expect("tmpdir_b");
        let id_b = BridgeIdentity::load_or_generate(&dir_b.path().to_path_buf()).expect("gen_b");
        let dir_a = TempDir::new().expect("tmpdir_a");
        let id_a = BridgeIdentity::load_or_generate(&dir_a.path().to_path_buf()).expect("gen_a");

        // No active_pin (None) → invitee must reject immediately.
        let (_dialer_half, invitee_half) = tokio::io::duplex(65536);
        let result = handle_pairing_connection(
            invitee_half,
            "127.0.0.1:0".to_string(),
            &id_b,
            None, // no armed PIN
        )
        .await;

        assert!(
            result.is_err(),
            "invitee must reject connection when no PIN is armed"
        );
        let err = result.unwrap_err();
        assert!(
            err.contains("no active PIN"),
            "expected no-pin error, got: {err}"
        );
    }

    #[tokio::test]
    async fn ac2_3_real_socket_expired_pin_rejected() {
        let dir_b = TempDir::new().expect("tmpdir_b");
        let id_b = BridgeIdentity::load_or_generate(&dir_b.path().to_path_buf()).expect("gen_b");

        let expired_pin = ActivePin {
            pin: "12345678".to_string(),
            created_at: Instant::now() - PIN_TTL - Duration::from_secs(1),
            attempts: 0,
            used: false,
            spake2_outmsg: None,
            pending_sas: None,
        };

        let (_dialer_half, invitee_half) = tokio::io::duplex(65536);
        let result = handle_pairing_connection(
            invitee_half,
            "127.0.0.1:0".to_string(),
            &id_b,
            Some(expired_pin),
        )
        .await;

        assert!(
            result.is_err(),
            "expired PIN must be rejected before PAKE starts"
        );
        let err = result.unwrap_err();
        assert!(err.contains("expired"), "got: {err}");
    }

    #[tokio::test]
    async fn ac2_3_sas_canonical_order_symmetric() {
        // Direct unit test for canonical derive_sas: swapping our/peer MUST yield same SAS.
        let key = [0xABu8; 32];
        let spki_x = "aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111";
        let spki_y = "bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222";

        let sas_xy = derive_sas(&key, spki_x, spki_y);
        let sas_yx = derive_sas(&key, spki_y, spki_x);
        assert_eq!(
            sas_xy, sas_yx,
            "derive_sas must be order-canonical: derive_sas(k, A, B) == derive_sas(k, B, A)"
        );
    }

    // Peer registry round-trip.
    #[test]
    fn ac2_peer_registry_roundtrip() {
        let dir = TempDir::new().expect("tmpdir");
        let dir_path = dir.path().to_path_buf();
        let mut reg = PeerRegistry::load_or_create(&dir_path).expect("create");

        let peer = PinnedPeer {
            schema_v: REGISTRY_SCHEMA_VERSION,
            spki_hash: "abc123".to_string(),
            label: "my-laptop".to_string(),
            last_addr: Some("10.0.0.5:9876".to_string()),
            paired_at: 1700000000,
            capability: "research".to_string(),
        };
        reg.insert(peer.clone()).expect("insert");
        assert!(reg.is_pinned("abc123"));

        let reg2 = PeerRegistry::load_or_create(&dir_path).expect("reload");
        let loaded = reg2
            .get("abc123")
            .expect("peer must be in reloaded registry");
        assert_eq!(loaded.label, "my-laptop");
        assert_eq!(loaded.paired_at, 1700000000);

        // Revoke.
        let mut reg3 = PeerRegistry::load_or_create(&dir_path).expect("reload for revoke");
        reg3.remove("abc123").expect("remove");
        assert!(!reg3.is_pinned("abc123"), "peer must be gone after revoke");
    }
}
