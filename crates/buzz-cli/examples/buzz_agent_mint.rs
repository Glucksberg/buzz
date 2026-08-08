//! Mint a Buzz-managed agent directly on a deployment host.
//!
//! The owner's private key is read from stdin and is never written to disk.
//! The generated agent key and NIP-OA attestation are stored in a mode-0600
//! systemd EnvironmentFile. A `.pending` credential makes network failures
//! resumable without creating another identity.

use base64::engine::general_purpose::STANDARD as B64;
use base64::Engine;
use nostr::{EventBuilder, JsonUtil, Keys, Kind, Tag, ToBech32};
use sha2::{Digest, Sha256};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

struct Args {
    name: String,
    relay: String,
    expected_owner: String,
    credential: PathBuf,
    agent_command: String,
    agent_args: String,
}

#[tokio::main]
async fn main() {
    let result = if std::env::args().nth(1).as_deref() == Some("publish-directory") {
        publish_directory().await
    } else {
        run().await
    };
    if let Err(error) = result {
        eprintln!("mint failed: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let args = parse_args()?;
    let owner_keys = read_owner_keys()?;
    let owner_pubkey = owner_keys.public_key().to_hex();
    if owner_pubkey != args.expected_owner.to_ascii_lowercase() {
        return Err(format!(
            "the supplied key belongs to owner {owner_pubkey}, expected {}",
            args.expected_owner
        ));
    }
    if args.credential.exists() {
        return Err(format!(
            "credential already exists: {}",
            args.credential.display()
        ));
    }

    let pending = pending_path(&args.credential);
    let (agent_keys, auth_tag) = if pending.exists() {
        load_pending(&pending, &owner_pubkey)?
    } else {
        let keys = Keys::generate();
        let auth_tag = buzz_sdk::nip_oa::compute_auth_tag(&owner_keys, &keys.public_key(), "")
            .map_err(|error| format!("failed to authorize agent: {error}"))?;
        write_pending(&pending, &keys, &auth_tag, &args)?;
        (keys, auth_tag)
    };

    let agent_pubkey = agent_keys.public_key().to_hex();
    let auth_tag_parts: Vec<String> = serde_json::from_str(&auth_tag)
        .map_err(|error| format!("invalid generated auth tag: {error}"))?;
    let auth_tag_wire = Tag::parse(auth_tag_parts)
        .map_err(|error| format!("invalid generated auth tag: {error}"))?;

    let profile_content = serde_json::json!({"display_name": args.name}).to_string();
    let profile = EventBuilder::new(Kind::Custom(0), profile_content)
        .tags([auth_tag_wire])
        .sign_with_keys(&agent_keys)
        .map_err(|error| format!("failed to sign agent profile: {error}"))?;

    let managed_content = serde_json::json!({
        "name": args.name,
        "parallelism": 10,
        "respond_to": "anyone"
    })
    .to_string();
    let d_tag = Tag::parse(["d", agent_pubkey.as_str()])
        .map_err(|error| format!("failed to build managed-agent tag: {error}"))?;
    let managed = EventBuilder::new(Kind::Custom(30177), managed_content)
        .tags([d_tag])
        .sign_with_keys(&owner_keys)
        .map_err(|error| format!("failed to sign managed-agent record: {error}"))?;

    let http_base = relay_http_base(&args.relay)?;
    post_event(&http_base, &agent_keys, &profile, Some(&auth_tag)).await?;
    let directory = build_directory_event(&agent_keys, &args.name, &[])?;
    post_event(&http_base, &agent_keys, &directory, Some(&auth_tag)).await?;
    post_event(&http_base, &owner_keys, &managed, None).await?;

    fs::rename(&pending, &args.credential)
        .map_err(|error| format!("failed to activate credential: {error}"))?;
    println!("{} identity minted successfully.", args.name);
    println!("AGENT_PUBKEY_HEX={agent_pubkey}");
    println!("OWNER_PUBKEY_HEX={owner_pubkey}");
    println!("CREDENTIAL={}", args.credential.display());
    Ok(())
}

async fn publish_directory() -> Result<(), String> {
    let mut name = None;
    let mut relay = None;
    let mut channels = Vec::new();
    let mut raw = std::env::args().skip(2);
    while let Some(flag) = raw.next() {
        let value = raw
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--name" => name = Some(value),
            "--relay" => relay = Some(value),
            "--channel" => {
                uuid::Uuid::parse_str(&value)
                    .map_err(|_| format!("invalid channel UUID: {value}"))?;
                channels.push(value);
            }
            _ => return Err(format!("unknown argument: {flag}")),
        }
    }
    let name = required(name, "--name")?;
    let relay = required(relay, "--relay")?;

    let mut input = String::new();
    std::io::stdin()
        .read_to_string(&mut input)
        .map_err(|error| format!("failed to read agent credentials: {error}"))?;
    let mut lines = input.lines();
    let private_key = lines.next().unwrap_or_default().trim();
    let auth_tag = lines.collect::<Vec<_>>().join("\n");
    let auth_tag = auth_tag.trim();
    if private_key.is_empty() || auth_tag.is_empty() {
        return Err("expected agent private key and NIP-OA auth tag on stdin".to_string());
    }
    let keys =
        Keys::parse(private_key).map_err(|error| format!("invalid agent private key: {error}"))?;
    buzz_sdk::nip_oa::verify_auth_tag(auth_tag, &keys.public_key())
        .map_err(|error| format!("invalid agent owner attestation: {error}"))?;

    let event = build_directory_event(&keys, &name, &channels)?;
    let http_base = relay_http_base(&relay)?;
    post_event(&http_base, &keys, &event, Some(auth_tag)).await?;
    println!(
        "DIRECTORY_PUBLISHED={}:{}",
        name,
        keys.public_key().to_hex()
    );
    Ok(())
}

fn build_directory_event(
    keys: &Keys,
    name: &str,
    channels: &[String],
) -> Result<nostr::Event, String> {
    let content = serde_json::json!({
        "name": name,
        "display_name": name,
        "agent_type": "agent",
        "channels": [],
        "channel_ids": channels,
        "capabilities": [],
        "status": "online",
        "respond_to": "anyone",
        "respond_to_allowlist": [],
        "channel_add_policy": "anyone"
    })
    .to_string();
    EventBuilder::new(Kind::Custom(10100), content)
        .sign_with_keys(keys)
        .map_err(|error| format!("failed to sign agent directory profile: {error}"))
}

fn parse_args() -> Result<Args, String> {
    let mut name = None;
    let mut relay = None;
    let mut expected_owner = None;
    let mut credential = None;
    let mut agent_command = None;
    let mut agent_args = String::new();
    let mut raw = std::env::args().skip(1);
    while let Some(flag) = raw.next() {
        let value = raw
            .next()
            .ok_or_else(|| format!("missing value for {flag}"))?;
        match flag.as_str() {
            "--name" => name = Some(value),
            "--relay" => relay = Some(value),
            "--expected-owner" => expected_owner = Some(value),
            "--credential" => credential = Some(PathBuf::from(value)),
            "--agent-command" => agent_command = Some(value),
            "--agent-args" => agent_args = value,
            _ => return Err(format!("unknown argument: {flag}")),
        }
    }
    Ok(Args {
        name: required(name, "--name")?,
        relay: required(relay, "--relay")?,
        expected_owner: required(expected_owner, "--expected-owner")?,
        credential: required(credential, "--credential")?,
        agent_command: required(agent_command, "--agent-command")?,
        agent_args,
    })
}

fn required<T>(value: Option<T>, name: &str) -> Result<T, String> {
    value.ok_or_else(|| format!("missing required argument {name}"))
}

fn read_owner_keys() -> Result<Keys, String> {
    let mut input = String::new();
    std::io::stdin()
        .read_to_string(&mut input)
        .map_err(|error| format!("failed to read owner key: {error}"))?;
    Keys::parse(input.trim()).map_err(|error| format!("invalid owner private key: {error}"))
}

fn pending_path(credential: &Path) -> PathBuf {
    PathBuf::from(format!("{}.pending", credential.display()))
}

fn write_pending(path: &Path, keys: &Keys, auth_tag: &str, args: &Args) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "credential path has no parent directory".to_string())?;
    fs::create_dir_all(parent)
        .map_err(|error| format!("failed to create credential dir: {error}"))?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| format!("failed to create pending credential: {error}"))?;
    let nsec = keys
        .secret_key()
        .to_bech32()
        .map_err(|error| format!("failed to encode agent key: {error}"))?;
    writeln!(file, "BUZZ_PRIVATE_KEY='{nsec}'").map_err(write_error)?;
    writeln!(file, "NOSTR_PRIVATE_KEY='{nsec}'").map_err(write_error)?;
    writeln!(file, "BUZZ_AUTH_TAG='{auth_tag}'").map_err(write_error)?;
    writeln!(file, "BUZZ_ACP_AGENT_COMMAND='{}'", args.agent_command).map_err(write_error)?;
    writeln!(file, "BUZZ_ACP_AGENT_ARGS='{}'", args.agent_args).map_err(write_error)?;
    file.sync_all().map_err(write_error)?;
    Ok(())
}

fn write_error(error: std::io::Error) -> String {
    format!("failed to write pending credential: {error}")
}

fn load_pending(path: &Path, owner_pubkey: &str) -> Result<(Keys, String), String> {
    let content = fs::read_to_string(path)
        .map_err(|error| format!("failed to read pending credential: {error}"))?;
    let private_key = env_value(&content, "BUZZ_PRIVATE_KEY")?;
    let auth_tag = env_value(&content, "BUZZ_AUTH_TAG")?;
    let keys = Keys::parse(&private_key)
        .map_err(|error| format!("invalid key in pending credential: {error}"))?;
    let verified_owner = buzz_sdk::nip_oa::verify_auth_tag(&auth_tag, &keys.public_key())
        .map_err(|error| format!("invalid auth tag in pending credential: {error}"))?;
    if verified_owner.to_hex() != owner_pubkey {
        return Err("pending credential belongs to a different owner".to_string());
    }
    Ok((keys, auth_tag))
}

fn env_value(content: &str, key: &str) -> Result<String, String> {
    let prefix = format!("{key}='");
    content
        .lines()
        .find_map(|line| line.strip_prefix(&prefix)?.strip_suffix('\''))
        .map(str::to_string)
        .ok_or_else(|| format!("missing {key} in pending credential"))
}

fn relay_http_base(relay: &str) -> Result<String, String> {
    let trimmed = relay.trim().trim_end_matches('/');
    if let Some(rest) = trimmed.strip_prefix("wss://") {
        Ok(format!("https://{rest}"))
    } else if let Some(rest) = trimmed.strip_prefix("ws://") {
        Ok(format!("http://{rest}"))
    } else if trimmed.starts_with("https://") || trimmed.starts_with("http://") {
        Ok(trimmed.to_string())
    } else {
        Err("relay must use ws://, wss://, http://, or https://".to_string())
    }
}

async fn post_event(
    http_base: &str,
    signer: &Keys,
    event: &nostr::Event,
    auth_tag: Option<&str>,
) -> Result<(), String> {
    let url = format!("{http_base}/events");
    let body = event.as_json().into_bytes();
    let auth = sign_nip98(signer, &url, &body)?;
    let client = reqwest::Client::new();
    let mut request = client
        .post(&url)
        .header("Authorization", auth)
        .header("Content-Type", "application/json");
    if let Some(value) = auth_tag {
        request = request.header("x-auth-tag", value);
    }
    let response = request
        .body(body)
        .send()
        .await
        .map_err(|error| format!("relay request failed: {error}"))?;
    if !response.status().is_success() {
        let status = response.status();
        let detail = response.text().await.unwrap_or_default();
        return Err(format!("relay rejected event (HTTP {status}): {detail}"));
    }
    Ok(())
}

fn sign_nip98(keys: &Keys, url: &str, body: &[u8]) -> Result<String, String> {
    let payload = hex::encode(Sha256::digest(body));
    let nonce = uuid::Uuid::new_v4().to_string();
    let tags = [
        Tag::parse(["u", url]).map_err(|error| error.to_string())?,
        Tag::parse(["method", "POST"]).map_err(|error| error.to_string())?,
        Tag::parse(["nonce", nonce.as_str()]).map_err(|error| error.to_string())?,
        Tag::parse(["payload", payload.as_str()]).map_err(|error| error.to_string())?,
    ];
    let event = EventBuilder::new(Kind::Custom(27235), "")
        .tags(tags)
        .sign_with_keys(keys)
        .map_err(|error| format!("failed to sign NIP-98 authorization: {error}"))?;
    Ok(format!("Nostr {}", B64.encode(event.as_json().as_bytes())))
}
