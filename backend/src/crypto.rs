// Mã hóa credentials bằng AES-256-GCM.
// Định dạng lưu DB: base64( nonce(12 bytes) || ciphertext+tag ).
use aes_gcm::{
    aead::{rand_core::RngCore, Aead, AeadCore, KeyInit, OsRng},
    Aes256Gcm, Key, Nonce,
};
use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};

const NONCE_LEN: usize = 12;

/// Lấy master key 32 bytes từ ENV `MASTER_KEY` (base64).
/// KHÔNG có ENV → sinh tạm thời (credentials cũ sẽ không giải mã được sau restart).
pub fn load_or_create_master_key() -> Result<[u8; 32]> {
    match std::env::var("MASTER_KEY") {
        Ok(v) => {
            let bytes = STANDARD
                .decode(v.trim())
                .context("MASTER_KEY không phải base64 hợp lệ")?;
            let arr: [u8; 32] = bytes
                .as_slice()
                .try_into()
                .map_err(|_| anyhow!("MASTER_KEY phải là 32 bytes sau base64 (dùng: openssl rand -base64 32)"))?;
            Ok(arr)
        }
        Err(_) => {
            tracing::warn!(
                "MASTER_KEY chưa set — sinh key tạm thời. Credentials lưu lần này sẽ KHÔNG giải mã được sau khi restart!"
            );
            let mut k = [0u8; 32];
            OsRng.fill_bytes(&mut k);
            Ok(k)
        }
    }
}

pub fn encrypt(key: &[u8; 32], plaintext: &str) -> Result<String> {
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Aes256Gcm::generate_nonce(&mut OsRng); // 12 bytes
    let ct = cipher
        .encrypt(&nonce, plaintext.as_bytes())
        .map_err(|e| anyhow!("encrypt: {e}"))?;
    let mut out = Vec::with_capacity(NONCE_LEN + ct.len());
    out.extend_from_slice(nonce.as_slice());
    out.extend_from_slice(&ct);
    Ok(STANDARD.encode(out))
}

pub fn decrypt(key: &[u8; 32], data: &str) -> Result<String> {
    let raw = STANDARD.decode(data).context("decrypt: base64 hỏng")?;
    if raw.len() < NONCE_LEN {
        return Err(anyhow!("decrypt: dữ liệu quá ngắn"));
    }
    let (nonce_bytes, ct) = raw.split_at(NONCE_LEN);
    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let pt = cipher
        .decrypt(Nonce::from_slice(nonce_bytes), ct)
        .map_err(|e| anyhow!("decrypt: {e} (sai MASTER_KEY?)"))?;
    String::from_utf8(pt).context("decrypt: kết quả không phải UTF-8")
}
