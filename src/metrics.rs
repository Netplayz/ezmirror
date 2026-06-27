use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::config::parse_mirrors_conf;
use crate::status::read_status;

const MIRRORS_CONF: &str = "/etc/ezmirror/mirrors.conf";

pub struct MetricsServer {
    running: Arc<AtomicBool>,
}

impl MetricsServer {
    pub fn new() -> Self {
        MetricsServer {
            running: Arc::new(AtomicBool::new(true)),
        }
    }

    pub fn stop(&self) {
        self.running.store(false, Ordering::SeqCst);
    }

    pub fn start(&self, port: u16) -> Result<(), String> {
        let addr = format!("127.0.0.1:{}", port);
        let listener = TcpListener::bind(&addr)
            .map_err(|e| format!("Failed to bind metrics server: {}", e))?;
        listener.set_nonblocking(true)
            .map_err(|e| format!("Failed to set nonblocking: {}", e))?;

        let running = self.running.clone();
        let _ = std::thread::spawn(move || {
            loop {
                if !running.load(Ordering::SeqCst) {
                    break;
                }
                match listener.accept() {
                    Ok((stream, _)) => {
                        handle_client(stream);
                    }
                    Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(Duration::from_millis(100));
                    }
                    Err(_) => break,
                }
            }
        });

        Ok(())
    }
}

fn handle_client(mut stream: TcpStream) {
    let mut buf = [0u8; 4096];
    let n = match stream.read(&mut buf) {
        Ok(n) if n > 0 => n,
        _ => return,
    };
    let request = String::from_utf8_lossy(&buf[..n]);
    let path = request.split_whitespace().nth(1).unwrap_or("/");

    let response = match path {
        "/metrics" => handle_metrics(),
        "/healthz" => handle_health(),
        _ => "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
    };

    stream.write_all(response.as_bytes()).ok();
}

fn handle_metrics() -> String {
    let header = "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n".to_string();

    let mut body = String::new();
    body.push_str("# HELP ezmirror_last_sync Unix timestamp of last sync per mirror\n");
    body.push_str("# TYPE ezmirror_last_sync gauge\n");
    body.push_str("# HELP ezmirror_sync_exit_code Exit code of last sync (0=ok)\n");
    body.push_str("# TYPE ezmirror_sync_exit_code gauge\n");
    body.push_str("# HELP ezmirror_disk_bytes Disk usage in bytes per mirror\n");
    body.push_str("# TYPE ezmirror_disk_bytes gauge\n");
    body.push_str("# HELP ezmirror_upstream_health Upstream health (1=ok, 0=fail)\n");
    body.push_str("# TYPE ezmirror_upstream_health gauge\n");
    body.push_str("# HELP ezmirror_upstream_response_ms Upstream response time in ms\n");
    body.push_str("# TYPE ezmirror_upstream_response_ms gauge\n");
    body.push_str("# HELP ezmirror_upstream_health_checked Timestamp of last upstream check\n");
    body.push_str("# TYPE ezmirror_upstream_health_checked gauge\n");

    if let Ok(mirrors) = parse_mirrors_conf(MIRRORS_CONF) {
        for m in &mirrors {
            let slug_clean = m.slug.replace('-', "_");
            match read_status(&m.slug) {
                Ok(st) => {
                    body.push_str(&format!("ezmirror_last_sync{{mirror=\"{slug_clean}\"}} {}\n", st.last_sync));
                    body.push_str(&format!("ezmirror_sync_exit_code{{mirror=\"{slug_clean}\"}} {}\n", st.exit_code));
                    body.push_str(&format!("ezmirror_disk_bytes{{mirror=\"{slug_clean}\"}} {}\n", st.disk_bytes));
                    body.push_str(&format!("ezmirror_upstream_health{{mirror=\"{slug_clean}\"}} {}\n",
                        if st.upstream_health == "ok" { 1 } else { 0 }));
                    body.push_str(&format!("ezmirror_upstream_response_ms{{mirror=\"{slug_clean}\"}} {}\n", st.upstream_response_time_ms));
                    body.push_str(&format!("ezmirror_upstream_health_checked{{mirror=\"{slug_clean}\"}} {}\n", st.upstream_health_checked));
                }
                Err(_) => {
                    body.push_str(&format!("ezmirror_last_sync{{mirror=\"{slug_clean}\"}} 0\n"));
                    body.push_str(&format!("ezmirror_sync_exit_code{{mirror=\"{slug_clean}\"}} -1\n"));
                    body.push_str(&format!("ezmirror_disk_bytes{{mirror=\"{slug_clean}\"}} 0\n"));
                    body.push_str(&format!("ezmirror_upstream_health{{mirror=\"{slug_clean}\"}} 0\n"));
                    body.push_str(&format!("ezmirror_upstream_response_ms{{mirror=\"{slug_clean}\"}} 0\n"));
                    body.push_str(&format!("ezmirror_upstream_health_checked{{mirror=\"{slug_clean}\"}} 0\n"));
                }
            }
        }
    }

    header + &body
}

fn handle_health() -> String {
    let healthy = if let Ok(mirrors) = parse_mirrors_conf(MIRRORS_CONF) {
        !mirrors.iter().any(|m| {
            read_status(&m.slug).map(|st| st.exit_code != 0).unwrap_or(false)
        })
    } else {
        true
    };

    let (code, status) = if healthy {
        ("200", "healthy")
    } else {
        ("503", "degraded")
    };

    format!(
        "HTTP/1.1 {code} OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n\
         {{\"status\":\"{status}\",\"service\":\"ezmirror\"}}\n"
    )
}
