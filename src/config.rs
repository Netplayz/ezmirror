use std::fs::File;
use std::io::{BufRead, BufReader};
use std::path::Path;

#[derive(Debug, Clone, Default)]
pub struct MirrorConfig {
    pub slug: String,
    pub name: String,
    pub desc: String,
    pub upstream: String,
    pub method: String,
    pub size: String,
    pub interval: String,
    pub bandwidth: i32,
    pub retention_days: i32,
    pub retention_max_gib: i32,
}

pub fn parse_mirrors_conf(path: &str) -> Result<Vec<MirrorConfig>, String> {
    let path = Path::new(path);
    let file = File::open(path).map_err(|e| format!("Failed to open {}: {}", path.display(), e))?;
    let reader = BufReader::new(file);

    let mut mirrors = Vec::new();

    for line in reader.lines() {
        let line = line.map_err(|e| format!("Read error: {}", e))?;
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        let fields: Vec<&str> = trimmed.split('|').collect();
        if fields.is_empty() || fields[0].is_empty() {
            continue;
        }

        let mut cfg = MirrorConfig::default();
        cfg.slug = fields[0].to_string();
        if fields.len() > 1 { cfg.name = fields[1].to_string(); }
        if fields.len() > 2 { cfg.desc = fields[2].to_string(); }
        if fields.len() > 3 { cfg.upstream = fields[3].to_string(); }
        if fields.len() > 4 { cfg.method = fields[4].to_string(); }
        if fields.len() > 5 { cfg.size = fields[5].to_string(); }
        if fields.len() > 7 { cfg.interval = fields[7].to_string(); }
        if fields.len() > 8 { cfg.bandwidth = fields[8].parse().unwrap_or(0); }
        if fields.len() > 9 { cfg.retention_days = fields[9].parse().unwrap_or(0); }
        if fields.len() > 10 { cfg.retention_max_gib = fields[10].parse().unwrap_or(0); }
        if cfg.interval.is_empty() { cfg.interval = "6h".to_string(); }

        mirrors.push(cfg);
    }

    Ok(mirrors)
}

pub fn interval_to_seconds(interval: &str) -> u64 {
    let s = interval.trim();
    if s.is_empty() {
        return 6 * 3600;
    }
    let num: u64 = s[..s.len()-1].parse().unwrap_or(6);
    match s.chars().last() {
        Some('m') | Some('M') => num * 60,
        Some('h') | Some('H') => num * 3600,
        Some('d') | Some('D') => num * 86400,
        _ => num * 3600,
    }
}
