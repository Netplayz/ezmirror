mod config;
mod metrics;
mod status;
mod sync;

use std::fs;
use std::process;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use clap::Parser;

const MIRRORS_CONF: &str = "/etc/ezmirror/mirrors.conf";
const PID_FILE: &str = "/var/run/ezmirord.pid";

static RUNNING: AtomicBool = AtomicBool::new(true);

#[derive(Parser)]
#[command(name = "ezmirord", version, about = "ezmirror sync daemon")]
struct Cli {
    #[arg(short = 'd', long = "daemon")]
    daemon: bool,

    #[arg(short = 'p', long = "port", default_value = "9633")]
    port: u16,

    #[arg(short = 's', long = "sync")]
    sync: bool,

    #[arg(long = "sync-slug")]
    sync_slug: Option<String>,

    #[arg(short = 'n', long = "dry-run")]
    dry_run: bool,

    #[arg(short = 't', long = "status")]
    status: bool,
}

fn main() {
    let cli = Cli::parse();

    let mirrors = match config::parse_mirrors_conf(MIRRORS_CONF) {
        Ok(m) => m,
        Err(e) => {
            eprintln!("Failed to read {}: {}", MIRRORS_CONF, e);
            process::exit(1);
        }
    };

    if cli.status {
        for m in &mirrors {
            match status::read_status(&m.slug) {
                Ok(st) => {
                    println!("{}|{}|{}|{}|{}|{}",
                        m.slug, st.last_sync, st.exit_code, st.disk_bytes,
                        st.status, st.upstream_health);
                }
                Err(_) => {
                    println!("{}|0|0|0|unknown|unknown", m.slug);
                }
            }
        }
        return;
    }

    if cli.sync {
        let targets: Vec<_> = if let Some(ref slug) = cli.sync_slug {
            mirrors.iter().filter(|m| m.slug == *slug).collect()
        } else {
            mirrors.iter().collect()
        };
        for m in &targets {
            if let Err(e) = sync::run_sync(m, cli.dry_run) {
                eprintln!("[{}] sync failed: {}", m.slug, e);
            }
        }
        return;
    }

    unsafe {
        libc::signal(libc::SIGTERM, sig_handler as *const () as libc::sighandler_t);
        libc::signal(libc::SIGINT, sig_handler as *const () as libc::sighandler_t);
        libc::signal(libc::SIGHUP, sig_handler as *const () as libc::sighandler_t);
    }

    if cli.daemon {
        daemonize();
    }

    write_pid();

    let metrics = metrics::MetricsServer::new();
    metrics.start(cli.port).unwrap_or_else(|e| {
        eprintln!("Warning: metrics server failed: {}", e);
    });

    println!("ezmirord started (pid {}), metrics on :{}", process::id(), cli.port);

    while RUNNING.load(Ordering::SeqCst) {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs() as i64;

        if let Ok(mirrors) = config::parse_mirrors_conf(MIRRORS_CONF) {
            for m in &mirrors {
                if !RUNNING.load(Ordering::SeqCst) {
                    break;
                }
                let interval = config::interval_to_seconds(&m.interval) as i64;
                let last = status::read_status(&m.slug)
                    .map(|st| st.last_sync)
                    .unwrap_or(0);

                if now - last >= interval {
                    if let Err(e) = sync::run_sync(m, false) {
                        eprintln!("[{}] sync failed: {}", m.slug, e);
                    }
                }
            }
        }

        for _ in 0..60 {
            if !RUNNING.load(Ordering::SeqCst) {
                break;
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    metrics.stop();
    fs::remove_file(PID_FILE).ok();
}

unsafe extern "C" fn sig_handler(sig: i32) {
    match sig {
        libc::SIGTERM | libc::SIGINT => {
            RUNNING.store(false, Ordering::SeqCst);
        }
        _ => {}
    }
}

fn daemonize() {
    unsafe {
        let pid = libc::fork();
        if pid < 0 { process::exit(1); }
        if pid > 0 { process::exit(0); }

        if libc::setsid() < 0 { process::exit(1); }

        libc::signal(libc::SIGCHLD, libc::SIG_IGN);

        let pid = libc::fork();
        if pid < 0 { process::exit(1); }
        if pid > 0 { process::exit(0); }

        libc::umask(0);
        libc::chdir("/\0".as_ptr() as *const _);

        let devnull = libc::open("/dev/null\0".as_ptr() as *const _, libc::O_RDWR);
        if devnull >= 0 {
            libc::dup2(devnull, 0);
            libc::dup2(devnull, 1);
            libc::dup2(devnull, 2);
            if devnull > 2 { libc::close(devnull); }
        }
    }
}

fn write_pid() {
    if let Ok(data) = fs::read_to_string(PID_FILE) {
        if let Ok(pid) = data.trim().parse::<i32>() {
            unsafe {
                if libc::kill(pid, 0) == 0 {
                    eprintln!("ezmirord already running (pid {})", pid);
                    process::exit(1);
                }
            }
        }
    }
    fs::write(PID_FILE, format!("{}\n", process::id())).ok();
}
