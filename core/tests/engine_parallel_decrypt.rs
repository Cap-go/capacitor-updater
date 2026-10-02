//! Regression: encrypted manifest files are decrypted in parallel in one
//! directory and used to share temp file names. Own binary: it opens many
//! connections at once and must not compete with other tests.

mod support;

use std::sync::{Arc, Mutex, OnceLock};

use aes::cipher::{BlockEncrypt, KeyInit};
use base64::Engine as _;
use rsa::pkcs1::EncodeRsaPublicKey;
use serde_json::json;
use support::TestEngine;

fn sha256(bytes: &[u8]) -> String {
    capgo_updater_core::crypto::checksum::sha256_hex(bytes)
}

struct Keys {
    private: rsa::RsaPrivateKey,
    public_pem: String,
}

fn keys() -> &'static Keys {
    static KEYS: OnceLock<Keys> = OnceLock::new();
    KEYS.get_or_init(|| {
        let private = rsa::RsaPrivateKey::new(&mut rand::thread_rng(), 2048).unwrap();
        let public_pem = private
            .to_public_key()
            .to_pkcs1_pem(rsa::pkcs1::LineEnding::LF)
            .unwrap();
        Keys { private, public_pem }
    })
}

fn private_encrypt(data: &[u8]) -> Vec<u8> {
    keys().private.sign(rsa::Pkcs1v15Sign::new_unprefixed(), data).unwrap()
}

const AES_KEY: [u8; 16] = [7; 16];
const IV: [u8; 16] = [9; 16];

fn aes_encrypt(plain: &[u8]) -> Vec<u8> {
    let cipher = aes::Aes128::new(&AES_KEY.into());
    let pad = 16 - plain.len() % 16;
    let mut data = plain.to_vec();
    data.extend(std::iter::repeat(pad as u8).take(pad));
    let mut previous = IV;
    for block in data.chunks_mut(16) {
        for i in 0..16 {
            block[i] ^= previous[i];
        }
        let mut array = aes::Block::clone_from_slice(block);
        cipher.encrypt_block(&mut array);
        block.copy_from_slice(&array);
        previous.copy_from_slice(block);
    }
    data
}

fn session_key() -> String {
    let b64 = base64::engine::general_purpose::STANDARD;
    format!("{}:{}", b64.encode(IV), b64.encode(private_encrypt(&AES_KEY)))
}

fn encrypted_checksum(plain: &[u8]) -> String {
    let digest = capgo_updater_core::text::hex_decode(&sha256(plain)).unwrap();
    capgo_updater_core::text::hex_encode(&private_encrypt(&digest))
}

type Files = Arc<Mutex<Vec<(String, Vec<u8>)>>>;

struct RawServer {
    url: String,
}

/// Thread-per-connection HTTP/1.1 server (one request per connection).
fn serve(files: Files) -> RawServer {
    use std::io::{BufRead, BufReader, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let files = files.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut request_line = String::new();
                reader.read_line(&mut request_line).unwrap();
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                }
                let path = request_line
                    .split_whitespace()
                    .nth(1)
                    .unwrap_or("/")
                    .split('?')
                    .next()
                    .unwrap()
                    .to_string();
                let body = files
                    .lock()
                    .unwrap()
                    .iter()
                    .find(|(name, _)| *name == path)
                    .map(|(_, body)| body.clone());
                let (status, body) = match body {
                    Some(body) => ("200 OK", body),
                    None => ("404 Not Found", Vec::new()),
                };
                let head = format!(
                    "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                );
                let _ = stream.write_all(head.as_bytes());
                let _ = stream.write_all(&body);
                let _ = stream.flush();
            });
        }
    });
    RawServer { url }
}

#[test]
fn many_encrypted_manifest_files_decrypt_in_parallel() {
    let files: Files = Arc::default();
    let server = serve(files.clone());
    let t = TestEngine::new(json!({ "publicKey": keys().public_pem }));
    let mut manifest = Vec::new();
    let mut contents = Vec::new();
    for index in 0..64 {
        let name = format!("assets/file-{index}.js");
        let content = format!("console.log({index});").repeat(64).into_bytes();
        files
            .lock()
            .unwrap()
            .push((format!("/files/{name}"), aes_encrypt(&content)));
        manifest.push(json!({ "file_name": name, "file_hash": encrypted_checksum(&content), "download_url": format!("{}/files/{name}", server.url) }));
        contents.push((name, content));
    }
    let installed = t.call(
        "download",
        json!({ "version": "2", "manifest": manifest, "sessionKey": session_key() }),
    );
    let dir = t.root().join("versions").join(installed["id"].as_str().unwrap());
    for (name, content) in contents {
        assert_eq!(std::fs::read(dir.join(&name)).unwrap(), content, "{name}");
    }
}
