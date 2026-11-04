#![cfg(windows)]
#![deny(unsafe_code)]

use buzz_terminal::{env_fence::fence_env, path::user_shell_path, shell::resolve_shell};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// Exercise the Windows default-program spawn, not just the builder's env map.
#[test]
fn fenced_default_shell_spawns_echoes_and_exits() -> Result<(), String> {
    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|_| "native PTY could not open")?;
    // Use stock cmd syntax without depending on a customized ComSpec. Supply
    // the fixture through the real resolver; do not mutate the process env.
    let cmd_path =
        std::path::PathBuf::from(std::env::var_os("SystemRoot").ok_or("SystemRoot unavailable")?)
            .join("System32")
            .join("cmd.exe");
    let shell = resolve_shell(cmd_path.to_str());
    let mut command = CommandBuilder::new_default_prog();
    fence_env(&mut command, &user_shell_path(), &shell);
    // Match production: leave cwd unset, including USERPROFILE resolution.
    let mut reader = pair.master.try_clone_reader().map_err(|_| "PTY reader")?;
    let mut writer = pair.master.take_writer().map_err(|_| "PTY writer")?;
    let mut child = pair
        .slave
        .spawn_command(command)
        .map_err(|_| "fenced default shell could not spawn")?;
    drop(pair.slave);

    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let mut killer = child.clone_killer();
    let watchdog = std::thread::spawn(move || {
        if done_rx.recv_timeout(Duration::from_secs(5)).is_err() {
            let _ = killer.kill();
        }
    });
    let (cursor_tx, cursor_rx) = mpsc::sync_channel(1);
    let (output_tx, output_rx) = mpsc::sync_channel(1);
    let reader_thread = std::thread::spawn(move || {
        const MARKER: &[u8] = b"BUZZ_NATIVE_ECHO_OK";
        let mut tail = Vec::new();
        let mut chunk = [0_u8; 1024];
        let mut requested_cursor = false;
        let mut echoed = false;
        loop {
            match reader.read(&mut chunk) {
                Ok(0) => break,
                Ok(count) => {
                    tail.extend_from_slice(&chunk[..count]);
                    echoed |= tail.windows(MARKER.len()).any(|b| b == MARKER);
                    if !requested_cursor && tail.windows(4).any(|b| b == b"\x1b[6n") {
                        let _ = cursor_tx.try_send(());
                        requested_cursor = true;
                    }
                    // Keep only overlap for markers split across reads. Continue
                    // draining until close so ConPTY cannot block on a full pipe.
                    let retain = (MARKER.len() - 1).min(tail.len());
                    tail.drain(..tail.len() - retain);
                }
                Err(_) => break,
            }
        }
        let _ = output_tx.send(echoed);
    });

    let interaction = (|| {
        // cmd removes the caret: input echo alone cannot satisfy the marker.
        writer
            .write_all(b"@echo BUZZ_NATIVE_ECHO^_OK\r\n@exit /b 0\r\n")
            .map_err(|_| "could not send echo and exit")?;
        writer.flush().map_err(|_| "could not flush PTY input")?;
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if cursor_rx.try_recv().is_ok() {
                // portable-pty enables ConPTY cursor inheritance; answer its DSR.
                writer.write_all(b"\x1b[1;1R").map_err(|_| "cursor reply")?;
                writer.flush().map_err(|_| "cursor flush")?;
            }
            if let Some(status) = child.try_wait().map_err(|_| "shell wait failed")? {
                return if status.success() {
                    Ok(())
                } else {
                    Err("default shell exited unsuccessfully")
                };
            }
            if Instant::now() >= deadline {
                return Err("default shell did not exit before deadline");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
    })();

    // Clean up before assertions, and never target processes by name.
    let _ = child.kill();
    let reap_deadline = Instant::now() + Duration::from_secs(1);
    let reaped = loop {
        if child.try_wait().is_ok_and(|status| status.is_some()) {
            break true;
        }
        if Instant::now() >= reap_deadline {
            break false;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    drop(writer);
    // Close the master while its reader is draining, not after joining it.
    drop(pair.master);
    let output = output_rx.recv_timeout(Duration::from_secs(1));
    let _ = done_tx.send(());
    let _ = watchdog.join();
    if reader_thread.is_finished() {
        reader_thread.join().map_err(|_| "PTY reader panicked")?;
    }
    if !reaped {
        return Err("test shell was not reaped before cleanup deadline".into());
    }
    interaction?;
    if !output.map_err(|_| "PTY reader did not finish after close")? {
        return Err("native shell did not execute the echo command".into());
    }
    Ok(())
}
