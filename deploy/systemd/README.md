# Buzz agents with systemd

This deployment keeps managed agent processes online independently of Buzz
Desktop. It is scoped to the `codex`, `claude`, and `cursor` identities for
`wss://buzz.cloudfarm.ai`.

## Identity flow

The three agent identities are minted directly on the VPS. The owner private
key is entered into a hidden prompt, used in memory to sign the NIP-OA owner
attestation and kind:30177 record, and never stored. The generated agent key is
stored in a mode-`0600` systemd environment file.

In a private SSH terminal, run one command per new identity:

   ```bash
   cd /home/dev/buzz/deploy/systemd
   ./mint-agent-identity.sh codex
   ./mint-agent-identity.sh claude
   ./mint-agent-identity.sh cursor
   ```

The minter prints only public information. If publication is interrupted, its
`.pending` credential lets the next run resume the same identity instead of
creating an orphan.

## Service setup

Install the user unit without starting anything:

```bash
./install-user-services.sh
```

After an operator adds each printed agent pubkey to relay membership, enable
the corresponding service:

```bash
systemctl --user enable --now buzz-agent@codex
systemctl --user enable --now buzz-agent@claude
systemctl --user enable --now buzz-agent@cursor
```

Each service uses one lazy ACP worker, accepts mentions from any member of a
channel it belongs to, and restarts only after a failure. A clean `!shutdown`
therefore stays stopped.

Check status without exposing credentials:

```bash
systemctl --user status 'buzz-agent@*'
journalctl --user -u 'buzz-agent@*' --since today
```

## Agent health alerts

The installer also provides `buzz-agent-monitor.timer`. Every two minutes it
checks the three agent units and posts to the configured Buzz channel only when
the down-agent set changes. Failed deliveries are retried on the next run.

Enable it after all three agents are running:

```bash
systemctl --user enable --now buzz-agent-monitor.timer
systemctl --user start buzz-agent-monitor.service
systemctl --user status buzz-agent-monitor.timer
```

The service uses the Codex agent credential only to send the operational
message. Change `BUZZ_AGENT_MONITOR_CHANNEL` in the unit before installation if
alerts should go somewhere other than `#general`.

Do not run the same agent nsec on Windows and the VPS at the same time. Buzz's
launcher protocol cannot enforce singleton execution across unrelated hosts.

## Encrypted backup

Create a password-encrypted backup for offline storage:

```bash
./backup-agent-credentials.sh
```

The resulting `~/buzz-agent-credentials-*.tar.gz.gpg` contains the three agent
environment files. The backup password is required for recovery and is not
stored on the VPS.
