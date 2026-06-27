use std::fs;
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::config::MirrorConfig;
use crate::status::{update_status, MirrorStatus};

const MIRROR_DIR: &str = "/var/www/html";

pub fn run_sync(cfg: &MirrorConfig, dry_run: bool) -> Result<i32, String> {
    if !check_upstream_health(cfg) {
        eprintln!("[{}] upstream unreachable, skipping", cfg.slug);
        return Ok(1);
    }

    if !is_sync_due(cfg) {
        println!("[{}] synced within {}, skipping", cfg.slug, cfg.interval);
        return Ok(0);
    }

    let local_dir = format!("{}/{}", MIRROR_DIR, cfg.slug);
    fs::create_dir_all(&local_dir)
        .map_err(|e| format!("mkdir failed: {}", e))?;

    let ret = if cfg.method == "rsync" || cfg.method == "mirror" {
        run_rsync(cfg, &local_dir, dry_run)?
    } else if cfg.method == "original" {
        println!("[{}] original mirror, no upstream sync", cfg.slug);
        return Ok(0);
    } else if cfg.method == "rclone-http" || cfg.method == "rclone-sftp" {
        run_rclone(cfg, &local_dir, dry_run)?
    } else {
        eprintln!("[{}] unknown method: {}", cfg.slug, cfg.method);
        return Ok(1);
    };

    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;

    let st = MirrorStatus {
        last_sync: now,
        exit_code: ret,
        status: if ret == 0 { "ok".into() } else { "error".into() },
        upstream_health: "ok".into(),
        upstream_health_checked: now,
        upstream_response_time_ms: 0,
        disk_bytes: get_disk_usage(&local_dir),
    };

    update_status(&cfg.slug, &st).ok();

    // Generate SHA256SUMS
    if !dry_run {
        generate_sha256sums(&local_dir);
    }

    Ok(ret)
}

fn is_sync_due(cfg: &MirrorConfig) -> bool {
    match crate::status::read_status(&cfg.slug) {
        Ok(st) => {
            let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;
            let interval = crate::config::interval_to_seconds(&cfg.interval) as i64;
            (now - st.last_sync) >= interval
        }
        Err(_) => true,
    }
}

fn check_upstream_health(cfg: &MirrorConfig) -> bool {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;

    if cfg.method == "original" {
        return true;
    }

    let start = std::time::Instant::now();
    let ok = match cfg.method.as_str() {
        "rsync" | "mirror" => {
            Command::new("timeout")
                .args(["10", "rsync", "--list-only", &cfg.upstream])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        }
        "rclone-http" => {
            Command::new("timeout")
                .args(["10", "curl", "-sI", &cfg.upstream])
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
        }
        "rclone-sftp" => {
            if let Some(colon) = cfg.upstream.find(':') {
                let remote = &cfg.upstream[..colon];
                Command::new("timeout")
                    .args(["10", "rclone", "lsd", &format!("{}:", remote)])
                    .stdout(std::process::Stdio::null())
                    .stderr(std::process::Stdio::null())
                    .status()
                    .map(|s| s.success())
                    .unwrap_or(false)
            } else {
                false
            }
        }
        _ => false,
    };

    let elapsed_ms = start.elapsed().as_millis() as i32;

    let st = MirrorStatus {
        last_sync: now,
        exit_code: if ok { 0 } else { 1 },
        upstream_response_time_ms: elapsed_ms,
        upstream_health_checked: now,
        upstream_health: if ok { "ok".into() } else { "fail".into() },
        status: if ok { "ok".into() } else { "error".into() },
        disk_bytes: get_disk_usage(&format!("{}/{}", MIRROR_DIR, cfg.slug)),
    };

    update_status(&cfg.slug, &st).ok();
    ok
}

fn run_rsync(cfg: &MirrorConfig, local_dir: &str, dry_run: bool) -> Result<i32, String> {
    let bw = if cfg.bandwidth > 0 {
        format!("--bwlimit={}m", cfg.bandwidth)
    } else {
        String::new()
    };

    let mut cmd = Command::new("rsync");
    cmd.args([
        "-rlptv", "--delete", "--safe-links", "--hard-links",
        "--timeout=300", "--contimeout=60",
        "--exclude=*.part", "--exclude=*.tmp",
    ]);
    if !bw.is_empty() { cmd.arg(&bw); }
    if dry_run { cmd.arg("--dry-run"); }
    cmd.arg(&cfg.upstream);
    cmd.arg(format!("{}/", local_dir));

    println!("[{}] syncing...", cfg.slug);
    let status = cmd.status().map_err(|e| format!("rsync failed: {}", e))?;
    Ok(status.code().unwrap_or(1))
}

fn run_rclone(cfg: &MirrorConfig, local_dir: &str, dry_run: bool) -> Result<i32, String> {
    let mut cmd = Command::new("rclone");

    if cfg.method == "rclone-http" {
        cmd.args([
            "sync", &format!(":http,url={}:", cfg.upstream),
            &format!("{}/", local_dir),
            "--transfers", "4",
            "--checkers", "8",
            "--retries", "3",
            "--exclude", "*.part",
        ]);
    } else {
        cmd.args(["sync", &cfg.upstream, &format!("{}/", local_dir)]);
    }

    if dry_run { cmd.arg("--dry-run"); }

    println!("[{}] syncing...", cfg.slug);
    let status = cmd.status().map_err(|e| format!("rclone failed: {}", e))?;
    Ok(status.code().unwrap_or(1))
}

fn get_disk_usage(path: &str) -> i64 {
    let p = Path::new(path);
    if !p.is_dir() { return 0; }
    let output = Command::new("du")
        .args(["-sb", path])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok());
    output
        .and_then(|s| s.split_whitespace().next()?.parse().ok())
        .unwrap_or(0)
}

fn generate_sha256sums(local_dir: &str) {
    let output = Command::new("find")
        .args([
            local_dir,
            "-maxdepth", "1",
            "-type", "f",
            "!", "-name", "*.html",
            "!", "-name", "SHA256SUMS",
            "!", "-name", "files.json",
            "!", "-name", "*.torrent",
        ])
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok());

    if let Some(files) = output {
        let sums: Vec<String> = files.lines().filter_map(|f| {
            let out = Command::new("sha256sum").arg(f).output().ok()?;
            String::from_utf8(out.stdout).ok()
        }).collect();

        if !sums.is_empty() {
            let sha_path = format!("{}/SHA256SUMS", local_dir);
            fs::write(&sha_path, sums.join("")).ok();
        }
    }
}
