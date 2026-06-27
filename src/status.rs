use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

const STATUS_FILE: &str = "/var/www/html/status.json";

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct MirrorStatus {
    pub last_sync: i64,
    pub exit_code: i32,
    pub disk_bytes: i64,
    pub status: String,
    pub upstream_health: String,
    pub upstream_health_checked: i64,
    pub upstream_response_time_ms: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GlobalStatus {
    pub generated: i64,
    pub mirrors: std::collections::HashMap<String, MirrorStatus>,
}

pub fn read_status(slug: &str) -> Result<MirrorStatus, String> {
    let path = Path::new(STATUS_FILE);
    if !path.exists() {
        return Err("status file not found".into());
    }
    let data = fs::read_to_string(path)
        .map_err(|e| format!("Failed to read status: {}", e))?;
    let global: GlobalStatus = serde_json::from_str(&data)
        .map_err(|e| format!("Failed to parse status: {}", e))?;
    global.mirrors.get(slug).cloned().ok_or_else(|| format!("no status for {}", slug))
}

pub fn update_status(slug: &str, st: &MirrorStatus) -> Result<(), String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default().as_secs() as i64;

    let path = Path::new(STATUS_FILE);
    let mut global = if path.exists() {
        let data = fs::read_to_string(path).unwrap_or_default();
        serde_json::from_str::<GlobalStatus>(&data).unwrap_or_default()
    } else {
        GlobalStatus::default()
    };

    global.generated = now;
    global.mirrors.insert(slug.to_string(), st.clone());

    let tmp = format!("{}.tmp", STATUS_FILE);
    let data = serde_json::to_string_pretty(&global)
        .map_err(|e| format!("Serialize error: {}", e))?;
    fs::write(&tmp, &data)
        .map_err(|e| format!("Write error: {}", e))?;
    fs::rename(&tmp, STATUS_FILE)
        .map_err(|e| format!("Rename error: {}", e))?;

    Ok(())
}
