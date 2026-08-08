//! Offline Nostr key helper for relay owner bootstrap.
//!
//! Never touches the network and never prints a private key that it did not
//! itself just generate. Intended to be run by a human directly in their own
//! terminal — not piped through any tool that logs or forwards output.
//!
//! Usage:
//!   buzz_keytool derive    # reads a private key (hex or nsec1...) from stdin,
//!                           # prints only the corresponding public key
//!   buzz_keytool generate  # creates a brand-new keypair, prints both keys once
//!   buzz_keytool verify-auth
//!                         # reads private key + NIP-OA auth tag on separate
//!                           stdin lines and prints only public material

use nostr::{Keys, ToBech32};
use std::io::Read;

fn main() {
    let mode = std::env::args().nth(1).unwrap_or_default();
    match mode.as_str() {
        "derive" => derive(),
        "generate" => generate(),
        "verify-auth" => verify_auth(),
        _ => {
            eprintln!("usage: buzz_keytool <derive|generate|verify-auth>");
            std::process::exit(2);
        }
    }
}

fn verify_auth() {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        eprintln!("failed to read credentials from stdin");
        std::process::exit(1);
    }
    let mut lines = input.lines();
    let private_key = lines.next().unwrap_or_default().trim();
    let auth_tag = lines.collect::<Vec<_>>().join("\n");
    let auth_tag = auth_tag.trim();
    if private_key.is_empty() || auth_tag.is_empty() {
        eprintln!("expected private key on line 1 and NIP-OA auth tag on line 2");
        std::process::exit(1);
    }

    let keys = match Keys::parse(private_key) {
        Ok(keys) => keys,
        Err(error) => {
            eprintln!("invalid private key: {error}");
            std::process::exit(1);
        }
    };
    let owner = match buzz_sdk::nip_oa::verify_auth_tag(auth_tag, &keys.public_key()) {
        Ok(owner) => owner,
        Err(error) => {
            eprintln!("invalid owner attestation: {error}");
            std::process::exit(1);
        }
    };

    println!("PUBKEY_HEX={}", keys.public_key().to_hex());
    println!("OWNER_PUBKEY_HEX={}", owner.to_hex());
}

fn derive() {
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        eprintln!("failed to read private key from stdin");
        std::process::exit(1);
    }
    let trimmed = input.trim();
    if trimmed.is_empty() {
        eprintln!("no private key provided on stdin");
        std::process::exit(1);
    }
    let keys = match Keys::parse(trimmed) {
        Ok(k) => k,
        Err(e) => {
            eprintln!("invalid private key: {e}");
            std::process::exit(1);
        }
    };
    // Only public material is printed. The private key that was read above
    // is dropped when this function returns and is never written anywhere.
    println!("PUBKEY_HEX={}", keys.public_key().to_hex());
    println!(
        "PUBKEY_NPUB={}",
        keys.public_key().to_bech32().unwrap_or_default()
    );
}

fn generate() {
    let keys = Keys::generate();
    println!("PUBKEY_HEX={}", keys.public_key().to_hex());
    println!(
        "PUBKEY_NPUB={}",
        keys.public_key().to_bech32().unwrap_or_default()
    );
    println!("PRIVKEY_HEX={}", keys.secret_key().to_secret_hex());
    println!(
        "PRIVKEY_NSEC={}",
        keys.secret_key().to_bech32().unwrap_or_default()
    );
    eprintln!();
    eprintln!("Save PRIVKEY_NSEC somewhere safe (password manager) right now.");
    eprintln!("It is shown only this once and is not written to any file by this tool.");
}
