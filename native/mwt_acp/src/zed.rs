//! The shell's agents in a Zed settings file: **Claude (MWT)** and
//! **Codex (MWT)**, beside Zed's own. `mwt-boot` writes them into the VM's
//! `~/.config/zed/settings.json`, which Zed's remote server merges after
//! your own settings.
//!
//! Only those two entries of `agent_servers` are written; the rest of the
//! file stays. Zed's settings may hold comments, which a rewrite drops: the
//! file is rewritten only when the entries change, with a word on stderr
//! when it had any.

use crate::json::{self, object, string, Value};
use std::fs;
use std::path::Path;

/// The agents, as Zed lists them, and their registry ids.
pub const AGENTS: [(&str, &str); 2] =
    [("Claude (MWT)", "claude-acp"), ("Codex (MWT)", "codex-acp")];

/// The same agents as MWT wrote them when it was MDT: dropped, so Zed
/// doesn't list them twice.
pub const FORMER_AGENTS: [&str; 2] = ["Claude (MDT)", "Codex (MDT)"];

/// Puts the agents in `file`, each starting `command` with its registry id.
/// Whether the file changed.
pub fn write_agents(file: &Path, command: &str) -> Result<bool, String> {
    let before = match fs::read_to_string(file) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("{}: {e}", file.display())),
    };
    let mut settings = match before.as_deref().map(str::trim) {
        None | Some("") => Value::Object(vec![]),
        Some(text) => json::parse_lenient(text)
            .map_err(|e| format!("{}: {e}; left as it is", file.display()))?,
    };
    if !matches!(settings, Value::Object(_)) {
        return Err(format!(
            "{}: not a settings object; left as it is",
            file.display()
        ));
    }

    let mut servers = match settings.get("agent_servers") {
        Some(servers @ Value::Object(_)) => servers.clone(),
        _ => Value::Object(vec![]),
    };
    for name in FORMER_AGENTS {
        servers.remove(name);
    }
    for (name, agent) in AGENTS {
        servers.set(
            name,
            object(vec![
                ("type", string("custom")),
                ("command", string(command)),
                ("args", Value::Array(vec![string(agent)])),
            ]),
        );
    }
    settings.set("agent_servers", servers);

    let after = settings.to_pretty();
    if before.as_deref() == Some(after.as_str()) {
        return Ok(false);
    }
    if before
        .as_deref()
        .is_some_and(|text| !text.trim().is_empty() && json::parse(text.trim()).is_err())
    {
        eprintln!(
            "mwt-acp: {} had comments or trailing commas; rewriting it drops them",
            file.display()
        );
    }
    if let Some(parent) = file.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("{}: {e}", parent.display()))?;
    }
    let partial = file.with_extension("json.mwt-partial");
    fs::write(&partial, after).map_err(|e| format!("{}: {e}", partial.display()))?;
    fs::rename(&partial, file).map_err(|e| format!("{}: {e}", file.display()))?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("mwt-acp-zed-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir.join("zed/settings.json")
    }

    #[test]
    fn creates_the_file_with_both_agents() {
        let file = scratch("create");
        assert_eq!(write_agents(&file, "/mnt/mwt/bin/mwt-acp"), Ok(true));
        let settings = json::parse(fs::read_to_string(&file).unwrap().trim()).unwrap();
        let claude = settings.at(&["agent_servers", "Claude (MWT)"]).unwrap();
        assert_eq!(claude.get("type").and_then(Value::as_str), Some("custom"));
        assert_eq!(
            claude.get("command").and_then(Value::as_str),
            Some("/mnt/mwt/bin/mwt-acp")
        );
        assert_eq!(
            claude.get("args"),
            Some(&Value::Array(vec![string("claude-acp")]))
        );
        assert!(settings.at(&["agent_servers", "Codex (MWT)"]).is_some());
        // Again: nothing to change.
        assert_eq!(write_agents(&file, "/mnt/mwt/bin/mwt-acp"), Ok(false));
        let _ = fs::remove_dir_all(file.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn keeps_the_rest_of_the_file() {
        let file = scratch("merge");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(
            &file,
            "// mine\n{\"theme\": \"One Dark\", \"agent_servers\": {\"Mine\": {\"type\": \"custom\", \"command\": \"x\"}, \"Claude (MWT)\": {\"command\": \"old\"}, \"Codex (MDT)\": {\"command\": \"older\"},},}\n",
        )
        .unwrap();
        assert_eq!(write_agents(&file, "/new"), Ok(true));
        let settings = json::parse(fs::read_to_string(&file).unwrap().trim()).unwrap();
        assert_eq!(
            settings.get("theme").and_then(Value::as_str),
            Some("One Dark")
        );
        assert!(settings.at(&["agent_servers", "Mine"]).is_some());
        assert!(settings.at(&["agent_servers", "Codex (MDT)"]).is_none());
        assert_eq!(
            settings
                .at(&["agent_servers", "Claude (MWT)", "command"])
                .and_then(Value::as_str),
            Some("/new")
        );
        let _ = fs::remove_dir_all(file.parent().unwrap().parent().unwrap());
    }

    #[test]
    fn leaves_a_file_it_cannot_read() {
        let file = scratch("broken");
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(&file, "{\"theme\": ").unwrap();
        assert!(write_agents(&file, "/new").is_err());
        assert_eq!(fs::read_to_string(&file).unwrap(), "{\"theme\": ");
        let _ = fs::remove_dir_all(file.parent().unwrap().parent().unwrap());
    }
}
