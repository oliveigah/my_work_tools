//! Which adapter to start for an agent: the version the ACP registry names,
//! as Zed would start it.
//!
//! Zed installs or updates a registry agent only when a thread starts with
//! Zed's own entry for it. The shell's agents are other entries, so it
//! follows the registry itself: it starts Zed's installed copy when that is
//! the version the registry names, else its own copy, installed as the
//! registry says (an archive checked against its sha256, or an npm
//! package). Nobody updates anything by hand.
//!
//! The registry is Zed's copy in the VM when fresh (Zed refreshes it
//! hourly), else the shell's own, fetched at most once a day. With neither,
//! or when installing fails, the newest copy Zed has installed is started,
//! whatever its version.

use crate::json::{self, Value};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

pub const REGISTRY_URL: &str =
    "https://cdn.agentclientprotocol.com/registry/v1/latest/registry.json";
const FRESH: Duration = Duration::from_secs(24 * 60 * 60);
const KEEP_OLD: Duration = Duration::from_secs(7 * 24 * 60 * 60);

/// A program to start, with its arguments and what to add to its
/// environment.
#[derive(Debug, PartialEq)]
pub struct Launch {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// Where things are; each one can be set from the environment, for tests.
pub struct Places {
    /// Zed's data folder (`~/.local/share/zed`).
    pub zed: PathBuf,
    /// The shell's own registry copy and adapters.
    pub cache: PathBuf,
    /// A registry file to read instead of any other.
    pub registry_file: Option<PathBuf>,
    pub registry_url: String,
    /// Whether it may fetch and install.
    pub online: bool,
    /// The registry's name for this machine (`linux-x86_64`).
    pub platform: String,
}

impl Places {
    pub fn from_env() -> Places {
        let var = |name: &str| {
            std::env::var_os(name)
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        };
        let home = var("HOME").unwrap_or_else(|| PathBuf::from("/root"));
        let zed = var("MWT_ACP_ZED_DATA").unwrap_or_else(|| {
            var("XDG_DATA_HOME")
                .unwrap_or_else(|| home.join(".local/share"))
                .join("zed")
        });
        let cache = var("MWT_ACP_CACHE").unwrap_or_else(|| {
            if Path::new("/cache").is_dir() {
                PathBuf::from("/cache/mwt-acp")
            } else {
                var("XDG_CACHE_HOME")
                    .unwrap_or_else(|| home.join(".cache"))
                    .join("mwt-acp")
            }
        });
        Places {
            zed,
            cache,
            registry_file: var("MWT_ACP_REGISTRY"),
            registry_url: std::env::var("MWT_ACP_REGISTRY_URL")
                .unwrap_or_else(|_| REGISTRY_URL.to_string()),
            online: std::env::var("MWT_ACP_OFFLINE")
                .map(|v| v.is_empty())
                .unwrap_or(true),
            platform: format!("linux-{}", std::env::consts::ARCH),
        }
    }

    fn zed_registry(&self) -> PathBuf {
        self.zed.join("external_agents/registry")
    }
}

/// The adapter to start for `agent` (a registry id: `claude-acp`).
pub fn resolve(agent: &str, places: &Places) -> Result<Launch, String> {
    let mut launch = match from_registry(agent, places) {
        Ok(launch) => launch,
        Err(error) => match newest_installed(agent, places) {
            Some(launch) => {
                eprintln!("mwt-acp: {error}; starting the newest copy Zed installed");
                launch
            }
            None => return Err(error),
        },
    };
    // As Zed starts its own: no browser in the VM, and Claude's adapter
    // with no API key of the environment's.
    launch.env.push(("NO_BROWSER".into(), "1".into()));
    if agent == "claude-acp" {
        launch.env.push(("ANTHROPIC_API_KEY".into(), String::new()));
    }
    Ok(launch)
}

fn from_registry(agent: &str, places: &Places) -> Result<Launch, String> {
    let registry = load_registry(places)?;
    let entry = registry
        .get("agents")
        .and_then(Value::as_array)
        .and_then(|agents| {
            agents
                .iter()
                .find(|a| a.get("id").and_then(Value::as_str) == Some(agent))
        })
        .ok_or_else(|| format!("the ACP registry has no agent {agent}"))?;
    let version = entry
        .get("version")
        .and_then(Value::as_str)
        .filter(|v| safe_name(v))
        .ok_or_else(|| format!("the ACP registry gives {agent} no version"))?;
    let distribution = entry
        .get("distribution")
        .ok_or_else(|| format!("the ACP registry gives {agent} no distribution"))?;

    if let Some(target) = distribution.at(&["binary", &places.platform]) {
        archive_agent(agent, version, target, places)
    } else if let Some(npx) = distribution.get("npx") {
        npx_agent(agent, version, npx, places)
    } else {
        Err(format!(
            "the ACP registry has no {} build of {agent}",
            places.platform
        ))
    }
}

fn load_registry(places: &Places) -> Result<Value, String> {
    if let Some(file) = &places.registry_file {
        return read_json(file);
    }
    let zed_copy = places.zed_registry().join("registry.json");
    let own_copy = places.cache.join("registry.json");
    for copy in [&zed_copy, &own_copy] {
        if fresh(copy) {
            if let Ok(registry) = read_json(copy) {
                return Ok(registry);
            }
        }
    }
    if places.online {
        match fetch(&places.registry_url, &own_copy, 60) {
            Ok(()) => return read_json(&own_copy),
            Err(error) => eprintln!("mwt-acp: could not fetch the ACP registry: {error}"),
        }
    }
    // Stale beats none.
    let stale = [&zed_copy, &own_copy]
        .into_iter()
        .find_map(|copy| read_json(copy).ok());
    stale.ok_or_else(|| "no ACP registry to read".to_string())
}

fn archive_agent(
    agent: &str,
    version: &str,
    target: &Value,
    places: &Places,
) -> Result<Launch, String> {
    let cmd = target
        .get("cmd")
        .and_then(Value::as_str)
        .ok_or("the registry entry has no cmd")?;
    let relative = command_path(cmd)?;
    let args = strings(target.get("args"));
    let env = pairs(target.get("env"));

    // Zed's copy of this version: v_<version>_<hashes>.
    let prefix = format!("v_{version}_");
    if let Some(dir) = subdirs(&places.zed_registry().join(agent))
        .into_iter()
        .find(|d| name_of(d).starts_with(&prefix) && d.join(&relative).is_file())
    {
        return Ok(Launch {
            program: dir.join(&relative),
            args,
            env,
        });
    }

    let dir = places.cache.join(agent).join(version);
    if !dir.join(&relative).is_file() {
        if !places.online {
            return Err(format!("{agent} {version} isn't installed"));
        }
        let url = target
            .get("archive")
            .and_then(Value::as_str)
            .ok_or("the registry entry has no archive")?;
        let sha256 = target.get("sha256").and_then(Value::as_str);
        install(&places.cache.join(agent), version, |tmp| {
            unpack(url, sha256, &relative, tmp)
        })?;
        if !dir.join(&relative).is_file() {
            return Err(format!("{agent} {version} has no {cmd} after installing"));
        }
    }
    Ok(Launch {
        program: dir.join(&relative),
        args,
        env,
    })
}

fn npx_agent(agent: &str, version: &str, npx: &Value, places: &Places) -> Result<Launch, String> {
    let package = npx
        .get("package")
        .and_then(Value::as_str)
        .ok_or("the registry entry has no package")?;
    let name = package_name(package);
    if !safe_package(name) {
        return Err(format!("odd package name {name}"));
    }
    let args = strings(npx.get("args"));
    let env = pairs(npx.get("env"));

    let zed_package = places
        .zed_registry()
        .join("npx")
        .join(agent)
        .join("node_modules")
        .join(name);
    let own_package = places
        .cache
        .join(agent)
        .join(version)
        .join("node_modules")
        .join(name);
    let package_dir = if package_version(&zed_package).as_deref() == Some(version) {
        zed_package
    } else {
        if package_version(&own_package).as_deref() != Some(version) {
            if !places.online {
                return Err(format!("{agent} {version} isn't installed"));
            }
            install(&places.cache.join(agent), version, |tmp| {
                npm_install(package, tmp)
            })?;
        }
        own_package
    };
    node_launch(&package_dir, name, args, env)
}

/// The newest copy of `agent` that Zed installed, whatever its version.
fn newest_installed(agent: &str, places: &Places) -> Option<Launch> {
    let mut archives = subdirs(&places.zed_registry().join(agent));
    archives.sort_by_key(|d| fs::metadata(d).and_then(|m| m.modified()).ok());
    for dir in archives.iter().rev() {
        // Without the registry the command's name is unknown: take the
        // adapter's (`claude-agent-acp`), not what it runs (`claude`).
        let found = fs::read_dir(dir)
            .ok()?
            .flatten()
            .map(|e| e.path())
            .find(|p| {
                let n = name_of(p);
                p.is_file() && (n.ends_with("-acp") || n == agent)
            });
        if let Some(program) = found {
            return Some(Launch {
                program,
                args: vec![],
                env: vec![],
            });
        }
    }
    let modules = places
        .zed_registry()
        .join("npx")
        .join(agent)
        .join("node_modules");
    for scope in subdirs(&modules) {
        for dir in std::iter::once(scope.clone()).chain(subdirs(&scope)) {
            if let Some(name) = read_json(&dir.join("package.json"))
                .ok()
                .and_then(|p| p.get("name").and_then(Value::as_str).map(str::to_string))
            {
                if let Ok(launch) = node_launch(&dir, &name, vec![], vec![]) {
                    return Some(launch);
                }
            }
        }
    }
    None
}

fn node_launch(
    package_dir: &Path,
    name: &str,
    mut args: Vec<String>,
    env: Vec<(String, String)>,
) -> Result<Launch, String> {
    let manifest = read_json(&package_dir.join("package.json"))?;
    let bin = match manifest.get("bin") {
        Some(Value::String(path)) => Some(path.clone()),
        Some(Value::Object(entries)) => {
            let short = name.rsplit('/').next().unwrap_or(name);
            entries
                .iter()
                .find(|(k, _)| k == short)
                .or_else(|| entries.first())
                .and_then(|(_, v)| v.as_str().map(str::to_string))
        }
        _ => None,
    }
    .ok_or_else(|| format!("{name} names no program to run"))?;
    let script = package_dir.join(command_path(&bin)?);
    args.insert(0, script.to_string_lossy().into_owned());
    Ok(Launch {
        program: PathBuf::from("node"),
        args,
        env,
    })
}

/// Installs a version into `base/version` through `fill`, which fills a
/// folder of its own; whoever renames first wins, so two shells starting
/// at once don't clash. Old versions go a week after they were replaced.
fn install(
    base: &Path,
    version: &str,
    fill: impl FnOnce(&Path) -> Result<(), String>,
) -> Result<(), String> {
    fs::create_dir_all(base).map_err(|e| format!("{}: {e}", base.display()))?;
    let tmp = base.join(format!(".install-{version}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?;
    eprintln!("mwt-acp: installing {} {version}", name_of(base));
    let filled = fill(&tmp);
    let target = base.join(version);
    let result = filled.and_then(|()| match fs::rename(&tmp, &target) {
        Ok(()) => Ok(()),
        Err(_) if target.is_dir() => Ok(()),
        Err(e) => Err(format!("{}: {e}", target.display())),
    });
    let _ = fs::remove_dir_all(&tmp);
    if result.is_ok() {
        let now = SystemTime::now();
        for dir in subdirs(base) {
            let old = fs::metadata(&dir)
                .and_then(|m| m.modified())
                .map(|t| now.duration_since(t).unwrap_or_default() > KEEP_OLD)
                .unwrap_or(false);
            if dir != target && old {
                let _ = fs::remove_dir_all(&dir);
            }
        }
    }
    result
}

fn unpack(url: &str, sha256: Option<&str>, command: &Path, dir: &Path) -> Result<(), String> {
    let path = url
        .split(['?', '#'])
        .next()
        .unwrap_or(url)
        .to_ascii_lowercase();
    let file = dir.join("download");
    fetch(url, &file, 900)?;
    if let Some(expected) = sha256 {
        let sum = run(Command::new("sha256sum").arg(&file))?;
        let actual = sum.split_whitespace().next().unwrap_or("");
        if !actual.eq_ignore_ascii_case(expected) {
            return Err(format!("{url} doesn't match its sha256"));
        }
    }
    let tar = |flag: &str| run(Command::new("tar").arg(flag).arg(&file).arg("-C").arg(dir));
    if path.ends_with(".tar.gz") || path.ends_with(".tgz") {
        tar("-xzf")?;
    } else if path.ends_with(".tar.bz2") || path.ends_with(".tbz2") {
        tar("-xjf")?;
    } else if path.ends_with(".tar.xz") {
        tar("-xJf")?;
    } else if path.ends_with(".zip") {
        run(Command::new("unzip")
            .arg("-q")
            .arg(&file)
            .arg("-d")
            .arg(dir))?;
    } else {
        // A bare program.
        let target = dir.join(command);
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        fs::copy(&file, &target).map_err(|e| e.to_string())?;
        run(Command::new("chmod").arg("+x").arg(&target))?;
    }
    let _ = fs::remove_file(&file);
    Ok(())
}

fn npm_install(package: &str, dir: &Path) -> Result<(), String> {
    run(Command::new("npm")
        .args([
            "install",
            "--no-save",
            "--no-audit",
            "--no-fund",
            "--no-package-lock",
            "--loglevel=error",
            "--prefix",
        ])
        .arg(dir)
        .arg(package))
    .map(|_| ())
}

fn fetch(url: &str, file: &Path, seconds: u32) -> Result<(), String> {
    if let Some(parent) = file.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let partial = file.with_extension("partial");
    run(Command::new("curl")
        .args(["-fsSL", "--max-time", &seconds.to_string(), "-o"])
        .arg(&partial)
        .arg(url))?;
    fs::rename(&partial, file).map_err(|e| e.to_string())
}

fn run(command: &mut Command) -> Result<String, String> {
    let name = command.get_program().to_string_lossy().into_owned();
    let output = command.output().map_err(|e| format!("{name}: {e}"))?;
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        let said = String::from_utf8_lossy(&output.stderr);
        Err(format!("{name} failed: {}", said.trim()))
    }
}

fn read_json(path: &Path) -> Result<Value, String> {
    let text = fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    json::parse(text.trim()).map_err(|e| format!("{}: {e}", path.display()))
}

fn fresh(path: &Path) -> bool {
    fs::metadata(path)
        .and_then(|m| m.modified())
        .map(|t| SystemTime::now().duration_since(t).unwrap_or_default() < FRESH)
        .unwrap_or(false)
}

fn package_version(dir: &Path) -> Option<String> {
    read_json(&dir.join("package.json"))
        .ok()?
        .get("version")?
        .as_str()
        .map(str::to_string)
}

/// `@scope/name@1.2.3` -> `@scope/name`.
fn package_name(spec: &str) -> &str {
    match spec.char_indices().skip(1).find(|(_, c)| *c == '@') {
        Some((at, _)) => &spec[..at],
        None => spec,
    }
}

/// A path inside a folder: relative, without `..`.
fn command_path(cmd: &str) -> Result<PathBuf, String> {
    let path = Path::new(cmd.strip_prefix("./").unwrap_or(cmd));
    let inside = path
        .components()
        .all(|c| matches!(c, std::path::Component::Normal(_)));
    if inside && !cmd.is_empty() {
        Ok(path.to_path_buf())
    } else {
        Err(format!("command {cmd} isn't inside its folder"))
    }
}

fn safe_name(s: &str) -> bool {
    !s.is_empty()
        && s != "."
        && s != ".."
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "._+-".contains(c))
}

fn safe_package(s: &str) -> bool {
    !s.is_empty()
        && !s.contains("..")
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || "@/._-".contains(c))
}

fn strings(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|v| v.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn pairs(value: Option<&Value>) -> Vec<(String, String)> {
    match value {
        Some(Value::Object(members)) => members
            .iter()
            .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
            .collect(),
        _ => vec![],
    }
}

fn subdirs(dir: &Path) -> Vec<PathBuf> {
    fs::read_dir(dir)
        .map(|entries| {
            entries
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.is_dir() && !name_of(p).starts_with('.'))
                .collect()
        })
        .unwrap_or_default()
}

fn name_of(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Scratch {
            let dir =
                std::env::temp_dir().join(format!("mwt-acp-test-{name}-{}", std::process::id()));
            let _ = fs::remove_dir_all(&dir);
            fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }

        fn write(&self, path: &str, text: &str) -> PathBuf {
            let file = self.0.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(&file, text).unwrap();
            file
        }

        fn places(&self, registry: &str) -> Places {
            Places {
                zed: self.0.join("zed"),
                cache: self.0.join("cache"),
                registry_file: Some(self.write("registry.json", registry)),
                registry_url: String::new(),
                online: false,
                platform: "linux-x86_64".into(),
            }
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    const REGISTRY: &str = r#"{"version":"1","agents":[
      {"id":"claude-acp","version":"0.107.0","distribution":{
        "binary":{"linux-x86_64":{"archive":"https://example.com/claude.tar.gz","cmd":"./claude-agent-acp","sha256":"00"}},
        "npx":{"package":"@agentclientprotocol/claude-agent-acp@0.107.0"}}},
      {"id":"codex-acp","version":"2.6.0","distribution":{
        "npx":{"package":"@agentclientprotocol/codex-acp@2.6.0","args":["--acp"],"env":{"A":"1"}}}}]}"#;

    #[test]
    fn starts_zeds_copy_when_it_is_the_registry_version() {
        let s = Scratch::new("zed-archive");
        s.write(
            "zed/external_agents/registry/claude-acp/v_0.106.0_aa_bb/claude-agent-acp",
            "",
        );
        let program = s.write(
            "zed/external_agents/registry/claude-acp/v_0.107.0_cc_dd/claude-agent-acp",
            "",
        );
        let launch = resolve("claude-acp", &s.places(REGISTRY)).unwrap();
        assert_eq!(launch.program, program);
        assert!(launch
            .env
            .contains(&("ANTHROPIC_API_KEY".into(), String::new())));
        assert!(launch.env.contains(&("NO_BROWSER".into(), "1".into())));
    }

    #[test]
    fn starts_its_own_copy_when_zeds_is_older() {
        let s = Scratch::new("own-archive");
        s.write(
            "zed/external_agents/registry/claude-acp/v_0.106.0_aa_bb/claude-agent-acp",
            "",
        );
        let program = s.write("cache/claude-acp/0.107.0/claude-agent-acp", "");
        assert_eq!(
            resolve("claude-acp", &s.places(REGISTRY)).unwrap().program,
            program
        );
    }

    #[test]
    fn falls_back_to_zeds_newest_copy_when_it_cannot_install() {
        let s = Scratch::new("fallback");
        let program = s.write(
            "zed/external_agents/registry/claude-acp/v_0.106.0_aa_bb/claude-agent-acp",
            "",
        );
        assert_eq!(
            resolve("claude-acp", &s.places(REGISTRY)).unwrap().program,
            program
        );
    }

    #[test]
    fn runs_an_npm_package_with_node() {
        let s = Scratch::new("npx");
        let package = "zed/external_agents/registry/npx/codex-acp/node_modules/@agentclientprotocol/codex-acp";
        s.write(&format!("{package}/package.json"), r#"{"name":"@agentclientprotocol/codex-acp","version":"2.6.0","bin":{"codex-acp":"dist/index.js"}}"#);
        let launch = resolve("codex-acp", &s.places(REGISTRY)).unwrap();
        assert_eq!(launch.program, PathBuf::from("node"));
        assert_eq!(
            launch.args,
            vec![
                s.0.join(package)
                    .join("dist/index.js")
                    .to_string_lossy()
                    .into_owned(),
                "--acp".into()
            ]
        );
        assert!(launch.env.contains(&("A".into(), "1".into())));
    }

    #[test]
    fn says_what_is_missing_offline() {
        let s = Scratch::new("missing");
        let error = resolve("codex-acp", &s.places(REGISTRY)).unwrap_err();
        assert_eq!(error, "codex-acp 2.6.0 isn't installed");
        assert_eq!(
            resolve("gemini", &s.places(REGISTRY)).unwrap_err(),
            "the ACP registry has no agent gemini"
        );
    }

    #[test]
    fn installs_an_archive_and_checks_it() {
        let s = Scratch::new("install");
        let content = s.write("build/claude-agent-acp", "#!/bin/sh\n");
        run(Command::new("tar")
            .arg("-czf")
            .arg(s.0.join("a.tar.gz"))
            .arg("-C")
            .arg(content.parent().unwrap())
            .arg("claude-agent-acp"))
        .unwrap();
        let sum = run(Command::new("sha256sum").arg(s.0.join("a.tar.gz"))).unwrap();
        let sum = sum.split_whitespace().next().unwrap();
        let url = format!("file://{}", s.0.join("a.tar.gz").display());
        let registry = format!(
            r#"{{"agents":[{{"id":"claude-acp","version":"0.108.0","distribution":{{"binary":{{"linux-x86_64":{{"archive":"{url}","cmd":"./claude-agent-acp","sha256":"{sum}"}}}}}}}}]}}"#
        );
        let mut places = s.places(&registry);
        places.online = true;
        let launch = resolve("claude-acp", &places).unwrap();
        assert_eq!(
            launch.program,
            s.0.join("cache/claude-acp/0.108.0/claude-agent-acp")
        );
        assert!(launch.program.is_file());

        let bad = registry.replace(sum, "0000").replace("0.108.0", "0.109.0");
        let mut places = s.places(&bad);
        places.online = true;
        places.zed = s.0.join("no-zed");
        assert_eq!(
            resolve("claude-acp", &places).unwrap_err(),
            format!("{url} doesn't match its sha256")
        );
        assert!(!s.0.join("cache/claude-acp/0.109.0").exists());
    }

    #[test]
    fn refuses_commands_outside_their_folder() {
        assert!(command_path("../x").is_err());
        assert!(command_path("/bin/sh").is_err());
        assert_eq!(command_path("./bin/a").unwrap(), PathBuf::from("bin/a"));
    }

    #[test]
    fn names_packages() {
        assert_eq!(package_name("@scope/name@1.2.3"), "@scope/name");
        assert_eq!(package_name("name@1"), "name");
        assert_eq!(package_name("@scope/name"), "@scope/name");
    }
}
