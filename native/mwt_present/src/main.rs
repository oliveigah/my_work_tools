//! MWT's presentations: a token grant's placeholder shown the way a tool
//! family looks for its credential, for one command's lifetime.
//!
//! `mwt exec GRANT -- COMMAND` ends by running `mwt-present KIND -- COMMAND`
//! when the grant asks for a presentation, so the binary owns the child, its
//! signals and its exit status. It holds only placeholders: adding one is no
//! trust decision. What it serves comes from variables the grant's
//! environment script sets, which the child doesn't get.
//!
//! The one presentation so far, `metadata`, is a cloud metadata server on a
//! loopback port: code that asks for default credentials finds the grant's
//! placeholder there (`GCE_METADATA_HOST`, `GCE_METADATA_IP`). Nothing
//! listens once the command ends.

use std::env;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::process::ExitStatusExt;
use std::process::{exit, Command};
use std::sync::atomic::{AtomicI32, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

mod metadata;

use metadata::Config;

/// The child's process id, for the signals this process passes on.
static CHILD: AtomicI32 = AtomicI32::new(0);

extern "C" {
    fn signal(signum: i32, handler: usize) -> usize;
    fn kill(pid: i32, sig: i32) -> i32;
}

extern "C" fn pass_on(sig: i32) {
    let pid = CHILD.load(Ordering::SeqCst);
    if pid > 0 {
        unsafe {
            kill(pid, sig);
        }
    }
}

const USAGE: &str = "mwt-present: use mwt exec GRANT_ID -- COMMAND [ARG...]";

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 4 || args[1] != "metadata" || args[2] != "--" {
        eprintln!("{USAGE}");
        exit(125);
    }

    let config = Arc::new(Config::from_env(|name| env::var(name).ok()));

    let listener = match TcpListener::bind("127.0.0.1:0") {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("mwt-present: can't listen on loopback: {error}");
            exit(125);
        }
    };

    let port = match listener.local_addr() {
        Ok(address) => address.port(),
        Err(error) => {
            eprintln!("mwt-present: {error}");
            exit(125);
        }
    };

    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let config = Arc::clone(&config);
            thread::spawn(move || serve(stream, &config));
        }
    });

    let mut command = Command::new(&args[3]);
    command.args(&args[4..]);

    for (name, _value) in env::vars() {
        if name.starts_with("MWT_PRESENT") {
            command.env_remove(name);
        }
    }

    let address = format!("127.0.0.1:{port}");
    command.env("GCE_METADATA_HOST", &address);
    command.env("GCE_METADATA_IP", &address);

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            eprintln!("mwt-present: {}: {error}", args[3]);
            exit(if error.kind() == std::io::ErrorKind::NotFound {
                127
            } else {
                126
            });
        }
    };

    CHILD.store(child.id() as i32, Ordering::SeqCst);

    // HUP, INT, QUIT, TERM go to the child, which decides how it ends.
    unsafe {
        for sig in [1, 2, 3, 15] {
            signal(sig, pass_on as *const () as usize);
        }
    }

    match child.wait() {
        Ok(status) => match status.code() {
            Some(code) => exit(code),
            None => exit(128 + status.signal().unwrap_or(0)),
        },
        Err(error) => {
            eprintln!("mwt-present: {error}");
            exit(125);
        }
    }
}

/// One request on one connection, then it closes.
fn serve(mut stream: TcpStream, config: &Config) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let mut head = Vec::new();
    let mut buffer = [0u8; 4096];

    while !head.windows(4).any(|w| w == b"\r\n\r\n") && head.len() < 16 * 1024 {
        match stream.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(n) => head.extend_from_slice(&buffer[..n]),
        }
    }

    let answer = match metadata::Request::parse(&head) {
        Some(request) => metadata::route(&request, config),
        None => metadata::Answer::status(400, "bad request"),
    };

    let _ = stream.write_all(&answer.bytes());
}
