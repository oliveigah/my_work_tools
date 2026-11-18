//! `mwt-acp AGENT`: what Zed starts for MWT's agents (see `lib.rs`).

use mwt_acp::link::Link;
use mwt_acp::proxy::Proxy;
use mwt_acp::{json, registry, zed};
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::{mpsc, Arc};
use std::thread;
use std::time::Duration;

const USAGE: &str = "\
Usage:
  mwt-acp AGENT                      start the agent's ACP adapter behind MWT's shell (what Zed runs)
  mwt-acp --resolve AGENT            say which adapter it would start, installing it if needed
  mwt-acp --zed-settings FILE [--command PATH]
                                     put MWT's agents in a Zed settings file (what mwt-boot runs)
  mwt-acp --version

AGENT is an ACP registry id: claude-acp, codex-acp.
Environment: MWT_CHANNEL (the channel to MWT, as for mwt), MWT_ACP_COMMAND (a JSON
array to start instead of the registry's adapter), MWT_ACP_CACHE, MWT_ACP_ZED_DATA,
MWT_ACP_REGISTRY (a registry file), MWT_ACP_OFFLINE.
";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let args: Vec<&str> = args.iter().map(String::as_str).collect();
    let code = match args.as_slice() {
        ["--version"] => {
            println!("mwt-acp {}", env!("CARGO_PKG_VERSION"));
            0
        }
        ["--resolve", agent] => match launch(agent) {
            Ok(launch) => {
                println!("{}", launch.program.display());
                for arg in &launch.args {
                    println!("  {arg}");
                }
                0
            }
            Err(error) => {
                eprintln!("mwt-acp: {error}");
                1
            }
        },
        ["--zed-settings", file] => settings(file, None),
        ["--zed-settings", file, "--command", command] => settings(file, Some(command)),
        ["--help" | "-h"] => {
            print!("{USAGE}");
            0
        }
        [agent] if !agent.starts_with('-') => run(agent),
        _ => {
            eprint!("{USAGE}");
            2
        }
    };
    std::process::exit(code);
}

fn launch(agent: &str) -> Result<registry::Launch, String> {
    if let Ok(command) = std::env::var("MWT_ACP_COMMAND") {
        let words: Vec<String> = json::parse(&command)
            .ok()
            .and_then(|v| {
                v.as_array().map(|a| {
                    a.iter()
                        .filter_map(|w| w.as_str().map(str::to_string))
                        .collect()
                })
            })
            .filter(|w: &Vec<String>| !w.is_empty())
            .ok_or("MWT_ACP_COMMAND must be a JSON array of strings")?;
        return Ok(registry::Launch {
            program: words[0].clone().into(),
            args: words[1..].to_vec(),
            env: vec![],
        });
    }
    registry::resolve(agent, &registry::Places::from_env())
}

fn settings(file: &str, command: Option<&str>) -> i32 {
    let command = match command {
        Some(command) => command.to_string(),
        None => match std::env::current_exe() {
            Ok(exe) => exe.to_string_lossy().into_owned(),
            Err(e) => {
                eprintln!("mwt-acp: {e}");
                return 1;
            }
        },
    };
    match zed::write_agents(std::path::Path::new(file), &command) {
        Ok(_) => 0,
        Err(error) => {
            eprintln!("mwt-acp: {error}");
            1
        }
    }
}

fn run(agent: &str) -> i32 {
    let launch = match launch(agent) {
        Ok(launch) => launch,
        Err(error) => {
            eprintln!("mwt-acp: can't start {agent}: {error}");
            return 1;
        }
    };
    let mut child = match Command::new(&launch.program)
        .args(&launch.args)
        .envs(launch.env.iter().map(|(k, v)| (k, v)))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
    {
        Ok(child) => child,
        Err(error) => {
            eprintln!("mwt-acp: can't start {}: {error}", launch.program.display());
            return 1;
        }
    };
    let to_agent = child.stdin.take().expect("piped stdin");
    let from_agent = child.stdout.take().expect("piped stdout");

    let (events, received) = mpsc::channel();
    let proxy = Arc::new(Proxy::new(
        Box::new(std::io::stdout()),
        Box::new(to_agent),
        events,
    ));

    let link = Link {
        address: std::env::var("MWT_CHANNEL")
            .unwrap_or_else(|_| "VSOCK-CONNECT:2:5000".to_string()),
        agent: agent.to_string(),
    };
    let linked = Arc::clone(&proxy);
    thread::spawn(move || link.run(linked, received));

    let client = Arc::clone(&proxy);
    thread::spawn(move || {
        let mut stdin = std::io::stdin().lock();
        each_line(&mut stdin, |line| client.from_client(line));
        client.close_agent();
    });

    let (drained, drained_rx) = mpsc::channel();
    let agent_side = Arc::clone(&proxy);
    thread::spawn(move || {
        each_line(&mut BufReader::new(from_agent), |line| {
            agent_side.from_agent(line)
        });
        let _ = drained.send(());
    });

    let status = child.wait();
    // What the agent wrote before it ended still goes to Zed.
    let _ = drained_rx.recv_timeout(Duration::from_secs(2));
    match status {
        Ok(status) => status.code().unwrap_or(1),
        Err(_) => 1,
    }
}

fn each_line(reader: &mut dyn BufRead, mut handle: impl FnMut(&[u8])) {
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => handle(&line),
        }
    }
}
