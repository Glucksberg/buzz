//! Add an existing cross-device agent roster to a Buzz channel.
//!
//! The channel owner's private key is read from stdin and kept inside this
//! process. It is never written to disk or placed in a child process argv/env.

use nostr::Keys;
use std::io::Read;

const OWNER_PUBKEY: &str = "40311b9e4cd014bd0a4e2a6b5e3654b2259d7cd2937f9dc0a61656543a63228c";
const RELAY: &str = "https://buzz.cloudfarm.ai";
const ROSTER: &[(&str, &str)] = &[
    (
        "Goose",
        "ee45014ee8d2ffd12d8d576487ad394bd09eb2b29a71a8468049ab0a7ff9aa82",
    ),
    (
        "Kimi",
        "be85d40fdb516760a9ffc3b1c4d06b57eddc6b5246d53fdd51a4058389c36094",
    ),
    (
        "Codex",
        "c2374d1adac80ff318caee358383f00019a830923a2427e440efa4c104085a42",
    ),
    (
        "Claude",
        "8ddea194fa6b61a0cf32a86e567ce368f5069d41c16668ad0f9b9d1ad934039a",
    ),
    (
        "Cursor",
        "dbfd5ae7137fbeb7ab453d39fa7b0f0c43a9d55eb7ed9422e3bae3fa948a7541",
    ),
];

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("roster update failed: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let channel = std::env::args()
        .nth(1)
        .ok_or_else(|| "usage: buzz_channel_roster <channel-uuid>".to_string())?;
    uuid::Uuid::parse_str(&channel).map_err(|_| format!("invalid channel UUID: {channel}"))?;

    let mut private_key = String::new();
    std::io::stdin()
        .read_to_string(&mut private_key)
        .map_err(|error| format!("failed to read owner key: {error}"))?;
    let private_key = private_key.trim().to_string();
    let keys =
        Keys::parse(&private_key).map_err(|error| format!("invalid owner private key: {error}"))?;
    let actual_owner = keys.public_key().to_hex();
    if actual_owner != OWNER_PUBKEY {
        return Err(format!(
            "the supplied key belongs to {actual_owner}, expected {OWNER_PUBKEY}"
        ));
    }

    for (name, pubkey) in ROSTER {
        let exit_code = buzz_cli::run_from_args([
            "buzz",
            "--relay",
            RELAY,
            "--private-key",
            private_key.as_str(),
            "channels",
            "add-member",
            "--channel",
            channel.as_str(),
            "--pubkey",
            pubkey,
            "--role",
            "bot",
        ])
        .await;
        if exit_code != 0 {
            return Err(format!("could not add {name} ({pubkey})"));
        }
        println!("ADDED={name}:{pubkey}");
    }

    println!("CHANNEL={channel}");
    println!("ROSTER_COUNT={}", ROSTER.len());
    Ok(())
}
