//! The shell end to end, with this test binary in every other part: Zed
//! (the shell's stdin and stdout), MWT (a Unix socket the shell's link
//! connects to) and the agent (this binary again, started by the shell with
//! `MWT_ACP_TEST_ROLE=agent`). Its own main, so it can be the agent.

use mwt_acp::json::{self, object, quote, string, Value};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{self, Receiver};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(5);

fn main() {
    if std::env::var("MWT_ACP_TEST_ROLE").as_deref() == Ok("agent") {
        fake_agent();
        return;
    }
    let tests: Vec<(&str, fn())> = vec![
        ("threads_open_work_and_close", threads_open_work_and_close),
        ("says_into_an_idle_thread", says_into_an_idle_thread),
        ("steers_into_a_running_turn", steers_into_a_running_turn),
        (
            "prompts_when_the_agent_cannot_steer",
            prompts_when_the_agent_cannot_steer,
        ),
        (
            "fails_for_a_thread_it_does_not_have",
            fails_for_a_thread_it_does_not_have,
        ),
        (
            "sends_its_threads_again_after_reconnecting",
            sends_its_threads_again_after_reconnecting,
        ),
        (
            "passes_lines_through_untouched",
            passes_lines_through_untouched,
        ),
        ("ends_when_the_agent_ends", ends_when_the_agent_ends),
    ];
    let filter = std::env::args().skip(1).find(|a| !a.starts_with('-'));
    let mut failed = 0;
    for (name, test) in tests {
        if filter.as_deref().is_some_and(|f| !name.contains(f)) {
            continue;
        }
        let outcome = std::panic::catch_unwind(test);
        println!(
            "test {name} ... {}",
            if outcome.is_ok() { "ok" } else { "FAILED" }
        );
        failed += outcome.is_err() as i32;
    }
    std::process::exit(failed.min(1));
}

// ---------------------------------------------------------------- tests --

fn threads_open_work_and_close() {
    let mwt = Mwt::listen("open");
    let mut zed = Zed::start(&mwt, true);
    let mut link = mwt.accept();
    let attach = link.next();
    assert_eq!(
        attach.get("command").and_then(Value::as_str),
        Some("attach")
    );
    assert_eq!(
        attach.get("agent").and_then(Value::as_str),
        Some("claude-acp")
    );

    let init = zed.request(
        1,
        "initialize",
        object(vec![("protocolVersion", Value::Number("1".into()))]),
    );
    assert_eq!(
        init.at(&["result", "_meta", "steering", "supported"]),
        Some(&Value::Bool(true))
    );
    let thread = zed.new_thread(2, "/work/a folder");
    assert_eq!(thread, "s-1");
    link.expect(&[
        ("type", "opened"),
        ("thread", "s-1"),
        ("folder", "/work/a folder"),
    ]);

    zed.prompt(3, &thread, "hello");
    zed.expect_text("agent_message_chunk", "echo: hello");
    zed.expect_response(3);
    link.expect(&[("type", "working"), ("thread", "s-1")]);
    link.expect(&[
        ("type", "title"),
        ("thread", "s-1"),
        ("title", "Fake title"),
    ]);
    link.expect(&[("type", "idle"), ("thread", "s-1")]);

    zed.request(
        4,
        "session/close",
        object(vec![("sessionId", string(&thread))]),
    );
    link.expect(&[("type", "closed"), ("thread", "s-1")]);
}

fn says_into_an_idle_thread() {
    let mwt = Mwt::listen("idle");
    let mut zed = Zed::start(&mwt, true);
    let mut link = mwt.accept();
    let thread = zed.ready(&mut link);

    link.say("say-1", &thread, "MWT (test): look at #21");
    zed.expect_text("user_message_chunk", "MWT (test): look at #21");
    zed.expect_text("agent_message_chunk", "echo: MWT (test): look at #21");
    link.expect(&[("type", "working"), ("thread", &thread)]);
    link.expect(&[("type", "said"), ("id", "say-1")]);
    link.expect(&[("type", "idle"), ("thread", &thread)]);
    // The answer to the shell's own prompt stays with the shell.
    zed.expect_silence(Duration::from_millis(300));
}

fn steers_into_a_running_turn() {
    let mwt = Mwt::listen("steer");
    let mut zed = Zed::start(&mwt, true);
    let mut link = mwt.accept();
    let thread = zed.ready(&mut link);

    zed.prompt(5, &thread, "slow work");
    link.expect(&[("type", "working"), ("thread", &thread)]);
    link.say("say-2", &thread, "MWT (test): also this");
    zed.expect_text("user_message_chunk", "MWT (test): also this");
    link.expect(&[("type", "said"), ("id", "say-2")]);
    zed.expect_text(
        "agent_message_chunk",
        "echo: slow work (steered: MWT (test): also this)",
    );
    zed.expect_response(5);
    link.expect(&[("type", "idle"), ("thread", &thread)]);
}

fn prompts_when_the_agent_cannot_steer() {
    let mwt = Mwt::listen("nosteer");
    let mut zed = Zed::start(&mwt, false);
    let mut link = mwt.accept();
    let thread = zed.ready(&mut link);

    link.say("say-3", &thread, "MWT (test): hi");
    link.expect(&[("type", "said"), ("id", "say-3")]);
    zed.expect_text("user_message_chunk", "MWT (test): hi");
    zed.expect_text("agent_message_chunk", "echo: MWT (test): hi");
}

fn fails_for_a_thread_it_does_not_have() {
    let mwt = Mwt::listen("unknown");
    let mut zed = Zed::start(&mwt, true);
    let mut link = mwt.accept();
    zed.ready(&mut link);
    link.say("say-4", "s-99", "hello?");
    link.expect(&[("type", "failed"), ("id", "say-4"), ("why", "closed")]);
}

fn sends_its_threads_again_after_reconnecting() {
    let mwt = Mwt::listen("reconnect");
    let mut zed = Zed::start(&mwt, true);
    let mut link = mwt.accept();
    let thread = zed.ready(&mut link);
    drop(link);

    let mut again = mwt.accept();
    assert_eq!(
        again.next().get("command").and_then(Value::as_str),
        Some("attach")
    );
    again.expect(&[
        ("type", "opened"),
        ("thread", &thread),
        ("folder", "/work/x"),
    ]);
    // And it still answers.
    again.say("say-5", &thread, "back");
    again.expect(&[("type", "said"), ("id", "say-5")]);
}

fn passes_lines_through_untouched() {
    let mwt = Mwt::listen("raw");
    let mut zed = Zed::start(&mwt, true);
    let _link = mwt.accept();
    for line in [
        "not json at all",
        r#"{"jsonrpc":"2.0", "id": 9 ,"method":"test/echo","params":{"n":[1, 2.50],"_meta":{"x":"é"}}}"#,
    ] {
        zed.send_raw(line);
        assert_eq!(zed.next_raw(), line);
    }
}

fn ends_when_the_agent_ends() {
    let mwt = Mwt::listen("end");
    let mut zed = Zed::start(&mwt, true);
    let mut link = mwt.accept();
    zed.ready(&mut link);
    drop(zed.stdin.take());
    let started = Instant::now();
    loop {
        if let Some(status) = zed.child.try_wait().unwrap() {
            assert_eq!(status.code(), Some(0));
            break;
        }
        assert!(started.elapsed() < WAIT, "the shell didn't end");
        thread::sleep(Duration::from_millis(20));
    }
    link.expect_end();
}

// ------------------------------------------------------------ Zed's part --

struct Zed {
    child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
}

impl Zed {
    fn start(mwt: &Mwt, steering: bool) -> Zed {
        let me = std::env::current_exe().unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_mwt-acp"))
            .arg("claude-acp")
            .env(
                "MWT_ACP_COMMAND",
                format!("[{}]", quote(&me.to_string_lossy())),
            )
            .env("MWT_ACP_TEST_ROLE", "agent")
            .env("FAKE_STEERING", if steering { "1" } else { "0" })
            .env(
                "MWT_CHANNEL",
                format!("UNIX-CONNECT:{}", mwt.path.display()),
            )
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let stdin = child.stdin.take();
        let lines = read_lines(BufReader::new(child.stdout.take().unwrap()));
        Zed {
            child,
            stdin,
            lines,
        }
    }

    /// Initialized, with one thread open in `/work/x` that MWT knows.
    fn ready(&mut self, link: &mut Link) -> String {
        link.next(); // attach
        self.request(
            1,
            "initialize",
            object(vec![("protocolVersion", Value::Number("1".into()))]),
        );
        let thread = self.new_thread(2, "/work/x");
        link.expect(&[("type", "opened"), ("thread", &thread)]);
        thread
    }

    fn new_thread(&mut self, id: u32, folder: &str) -> String {
        let answer = self.request(
            id,
            "session/new",
            object(vec![
                ("cwd", string(folder)),
                ("mcpServers", Value::Array(vec![])),
            ]),
        );
        answer
            .at(&["result", "sessionId"])
            .and_then(Value::as_str)
            .unwrap()
            .to_string()
    }

    fn prompt(&mut self, id: u32, thread: &str, text: &str) {
        let prompt = Value::Array(vec![object(vec![
            ("type", string("text")),
            ("text", string(text)),
        ])]);
        self.send(
            id,
            "session/prompt",
            object(vec![("sessionId", string(thread)), ("prompt", prompt)]),
        );
    }

    fn request(&mut self, id: u32, method: &str, params: Value) -> Value {
        self.send(id, method, params);
        self.expect_response(id)
    }

    fn send(&mut self, id: u32, method: &str, params: Value) {
        let message = object(vec![
            ("jsonrpc", string("2.0")),
            ("id", Value::Number(id.to_string())),
            ("method", string(method)),
            ("params", params),
        ]);
        self.send_raw(&message.to_json());
    }

    fn send_raw(&mut self, line: &str) {
        let stdin = self.stdin.as_mut().unwrap();
        stdin.write_all(line.as_bytes()).unwrap();
        stdin.write_all(b"\n").unwrap();
        stdin.flush().unwrap();
    }

    fn next_raw(&mut self) -> String {
        self.lines
            .recv_timeout(WAIT)
            .expect("nothing from the shell")
    }

    fn expect(&mut self, what: &str, matches: impl Fn(&Value) -> bool) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let line = self
                .lines
                .recv_timeout(left)
                .unwrap_or_else(|_| panic!("Zed never got {what}"));
            if let Ok(message) = json::parse(&line) {
                if matches(&message) {
                    return message;
                }
            }
        }
    }

    fn expect_response(&mut self, id: u32) -> Value {
        let id = Value::Number(id.to_string());
        self.expect(&format!("the answer to {}", id.to_json()), |m| {
            m.get("method").is_none() && m.get("id") == Some(&id)
        })
    }

    fn expect_text(&mut self, kind: &str, text: &str) {
        self.expect(&format!("{kind} {text:?}"), |m| {
            m.at(&["params", "update", "sessionUpdate"])
                .and_then(Value::as_str)
                == Some(kind)
                && m.at(&["params", "update", "content", "text"])
                    .and_then(Value::as_str)
                    == Some(text)
        });
    }

    /// Nothing arrives but the agent's updates: no answer Zed didn't ask for.
    fn expect_silence(&mut self, wait: Duration) {
        let deadline = Instant::now() + wait;
        while let Ok(line) = self
            .lines
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
        {
            let message = json::parse(&line).unwrap();
            assert!(
                message.get("method").is_some(),
                "Zed got an answer it never asked for: {line}"
            );
        }
    }
}

impl Drop for Zed {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ------------------------------------------------------------ MWT's part --

struct Mwt {
    path: PathBuf,
    listener: UnixListener,
}

struct Link {
    stream: UnixStream,
    lines: Receiver<String>,
}

impl Mwt {
    fn listen(name: &str) -> Mwt {
        let path = std::env::temp_dir().join(format!("mwt-acp-{name}-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        listener.set_nonblocking(true).unwrap();
        Mwt { path, listener }
    }

    fn accept(&self) -> Link {
        let deadline = Instant::now() + WAIT;
        loop {
            match self.listener.accept() {
                Ok((stream, _)) => {
                    stream.set_nonblocking(false).unwrap();
                    let lines = read_lines(BufReader::new(stream.try_clone().unwrap()));
                    return Link { stream, lines };
                }
                Err(_) if Instant::now() < deadline => thread::sleep(Duration::from_millis(20)),
                Err(e) => panic!("the shell never connected: {e}"),
            }
        }
    }
}

impl Drop for Mwt {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

impl Link {
    fn next(&mut self) -> Value {
        let line = self
            .lines
            .recv_timeout(WAIT)
            .expect("nothing from the shell's link");
        json::parse(&line).unwrap()
    }

    /// The next event with these fields; the others in between are skipped.
    fn expect(&mut self, fields: &[(&str, &str)]) -> Value {
        let deadline = Instant::now() + WAIT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let line = self
                .lines
                .recv_timeout(left)
                .unwrap_or_else(|_| panic!("MWT never heard {fields:?}"));
            let event = json::parse(&line).unwrap();
            if fields
                .iter()
                .all(|(k, v)| event.get(k).and_then(Value::as_str) == Some(v))
            {
                return event;
            }
        }
    }

    fn say(&mut self, id: &str, thread: &str, text: &str) {
        let message = object(vec![
            ("type", string("say")),
            ("id", string(id)),
            ("thread", string(thread)),
            ("text", string(text)),
        ]);
        self.stream
            .write_all(format!("{}\n", message.to_json()).as_bytes())
            .unwrap();
    }

    fn expect_end(&mut self) {
        let deadline = Instant::now() + WAIT;
        loop {
            match self
                .lines
                .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            {
                Ok(_) => continue,
                Err(mpsc::RecvTimeoutError::Disconnected) => return,
                Err(mpsc::RecvTimeoutError::Timeout) => panic!("the link stayed open"),
            }
        }
    }
}

impl Drop for Link {
    fn drop(&mut self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }
}

fn read_lines(reader: impl BufRead + Send + 'static) -> Receiver<String> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        for line in reader.lines() {
            match line {
                Ok(line) => {
                    if tx.send(line).is_err() {
                        return;
                    }
                }
                Err(_) => return,
            }
        }
    });
    rx
}

// ---------------------------------------------------------- the agent --

/// A small ACP agent: answers what the tests send. A prompt is echoed; one
/// starting with "slow" runs 600 ms, and a steer that arrives meanwhile
/// joins it.
fn fake_agent() {
    let steering = std::env::var("FAKE_STEERING").as_deref() == Ok("1");
    let out = Arc::new(Mutex::new(std::io::stdout()));
    let running: Arc<Mutex<Option<(String, Vec<String>)>>> = Arc::new(Mutex::new(None));
    let mut sessions = 0;
    let mut titled = false;

    let write = |out: &Arc<Mutex<std::io::Stdout>>, message: Value| {
        let mut out = out.lock().unwrap();
        writeln!(out, "{}", message.to_json()).unwrap();
        out.flush().unwrap();
    };
    let answer = |id: &Value, result: Value| {
        object(vec![
            ("jsonrpc", string("2.0")),
            ("id", id.clone()),
            ("result", result),
        ])
    };
    let update = |thread: &str, update: Value| {
        object(vec![
            ("jsonrpc", string("2.0")),
            ("method", string("session/update")),
            (
                "params",
                object(vec![("sessionId", string(thread)), ("update", update)]),
            ),
        ])
    };
    let chunk = |text: &str| {
        object(vec![
            ("sessionUpdate", string("agent_message_chunk")),
            (
                "content",
                object(vec![("type", string("text")), ("text", string(text))]),
            ),
        ])
    };

    for line in std::io::stdin().lock().lines() {
        let Ok(line) = line else { return };
        let Ok(message) = json::parse(&line) else {
            let mut out = out.lock().unwrap();
            writeln!(out, "{line}").unwrap();
            out.flush().unwrap();
            continue;
        };
        let id = message.get("id").cloned().unwrap_or(Value::Null);
        let thread = message
            .at(&["params", "sessionId"])
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let text = message
            .at(&["params", "prompt"])
            .and_then(Value::as_array)
            .and_then(|p| p.first())
            .and_then(|b| b.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        match message.get("method").and_then(Value::as_str).unwrap_or("") {
            "initialize" => write(
                &out,
                answer(
                    &id,
                    object(vec![
                        ("protocolVersion", Value::Number("1".into())),
                        (
                            "_meta",
                            object(vec![(
                                "steering",
                                object(vec![("supported", Value::Bool(steering))]),
                            )]),
                        ),
                    ]),
                ),
            ),
            "session/new" => {
                sessions += 1;
                write(
                    &out,
                    answer(
                        &id,
                        object(vec![("sessionId", string(&format!("s-{sessions}")))]),
                    ),
                );
            }
            "session/close" | "session/load" => write(&out, answer(&id, object(vec![]))),
            "test/echo" => {
                let mut out = out.lock().unwrap();
                writeln!(out, "{line}").unwrap();
                out.flush().unwrap();
            }
            "session/prompt" if text.starts_with("slow") => {
                *running.lock().unwrap() = Some((thread.clone(), vec![]));
                let (out, running) = (Arc::clone(&out), Arc::clone(&running));
                thread::spawn(move || {
                    thread::sleep(Duration::from_millis(600));
                    let steered = running
                        .lock()
                        .unwrap()
                        .take()
                        .map(|(_, s)| s)
                        .unwrap_or_default();
                    let said = if steered.is_empty() {
                        format!("echo: {text}")
                    } else {
                        format!("echo: {text} (steered: {})", steered.join("; "))
                    };
                    write(&out, update(&thread, chunk(&said)));
                    write(
                        &out,
                        answer(&id, object(vec![("stopReason", string("end_turn"))])),
                    );
                });
            }
            "session/prompt" => {
                write(&out, update(&thread, chunk(&format!("echo: {text}"))));
                if !titled {
                    titled = true;
                    write(
                        &out,
                        update(
                            &thread,
                            object(vec![
                                ("sessionUpdate", string("session_info_update")),
                                ("title", string("Fake title")),
                            ]),
                        ),
                    );
                }
                write(
                    &out,
                    answer(&id, object(vec![("stopReason", string("end_turn"))])),
                );
            }
            "_session/steering" => {
                let mut running = running.lock().unwrap();
                match running.as_mut() {
                    Some((on, steered)) if *on == thread => {
                        steered.push(text);
                        write(
                            &out,
                            answer(&id, object(vec![("outcome", string("injected"))])),
                        );
                    }
                    _ => write(
                        &out,
                        answer(
                            &id,
                            object(vec![
                                ("outcome", string("promptRequired")),
                                ("reason", string("noRunningTurn")),
                            ]),
                        ),
                    ),
                }
            }
            _ => {}
        }
    }
}
