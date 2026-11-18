//! The shell between Zed and an agent's ACP adapter.
//!
//! Every line goes through as it came, byte for byte. A few are read on the
//! way, to know the threads: `session/new`, `session/load`, `session/resume`
//! and `session/fork` and their answers (a thread opened, with its folder),
//! `session/close` (closed), `session/prompt` and its answer (working, then
//! idle), and `session_info_update` (its title). What changes goes to MWT
//! as an [`Event`].
//!
//! When MWT says something to a thread ([`Proxy::say`]), the shell shows it
//! in Zed as a user message (`user_message_chunk`) and gives it to the
//! agent: by `_session/steering` when the agent offers it, which joins a
//! running turn, else, and when no turn runs, by a `session/prompt` of its
//! own. Its own requests have ids Zed doesn't use (`mwt-acp-N`), and their
//! answers stay here, since Zed never asked.

use crate::json::{self, object, string, Value};
use std::collections::HashMap;
use std::io::Write;
use std::sync::mpsc::Sender;
use std::sync::Mutex;

/// What MWT hears about the threads, and about what it said.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Opened {
        thread: String,
        folder: String,
        title: Option<String>,
        working: bool,
    },
    Closed {
        thread: String,
    },
    Working {
        thread: String,
    },
    Idle {
        thread: String,
    },
    Title {
        thread: String,
        title: String,
    },
    Said {
        id: String,
    },
    Failed {
        id: String,
        why: String,
    },
    /// The connection to MWT ended (the link's own, never sent to MWT).
    LinkLost {
        generation: u64,
    },
}

impl Event {
    /// The event as a line for MWT, or `None` for the link's own.
    pub fn to_line(&self) -> Option<String> {
        let value = match self {
            Event::Opened {
                thread,
                folder,
                title,
                working,
            } => object(vec![
                ("type", string("opened")),
                ("thread", string(thread)),
                ("folder", string(folder)),
                ("title", title.as_deref().map(string).unwrap_or(Value::Null)),
                ("working", Value::Bool(*working)),
            ]),
            Event::Closed { thread } => {
                object(vec![("type", string("closed")), ("thread", string(thread))])
            }
            Event::Working { thread } => object(vec![
                ("type", string("working")),
                ("thread", string(thread)),
            ]),
            Event::Idle { thread } => {
                object(vec![("type", string("idle")), ("thread", string(thread))])
            }
            Event::Title { thread, title } => object(vec![
                ("type", string("title")),
                ("thread", string(thread)),
                ("title", string(title)),
            ]),
            Event::Said { id } => object(vec![("type", string("said")), ("id", string(id))]),
            Event::Failed { id, why } => object(vec![
                ("type", string("failed")),
                ("id", string(id)),
                ("why", string(why)),
            ]),
            Event::LinkLost { .. } => return None,
        };
        Some(value.to_json())
    }
}

struct Thread {
    folder: String,
    title: Option<String>,
    /// Prompts in flight, Zed's and the shell's own.
    prompts: u32,
}

impl Thread {
    fn working(&self) -> bool {
        self.prompts > 0
    }
}

/// A request from Zed whose answer says something about a thread.
enum ClientRequest {
    Initialize,
    Open {
        thread: Option<String>,
        folder: String,
    },
    Close {
        thread: String,
    },
    Prompt {
        thread: String,
    },
}

/// A request of the shell's own, for something MWT said.
enum OwnRequest {
    Steer {
        say: String,
        thread: String,
        text: String,
    },
    Prompt {
        thread: String,
    },
}

#[derive(Default)]
struct State {
    threads: HashMap<String, Thread>,
    /// Both keyed by the id as JSON, as answers carry it.
    client_requests: HashMap<String, ClientRequest>,
    own_requests: HashMap<String, OwnRequest>,
    steering: bool,
    next_own: u64,
}

pub struct Proxy {
    state: Mutex<State>,
    to_client: Mutex<Box<dyn Write + Send>>,
    to_agent: Mutex<Option<Box<dyn Write + Send>>>,
    events: Mutex<Sender<Event>>,
}

/// What to do with a line from the agent.
enum Verdict {
    Forward,
    Keep,
}

impl Proxy {
    pub fn new(
        to_client: Box<dyn Write + Send>,
        to_agent: Box<dyn Write + Send>,
        events: Sender<Event>,
    ) -> Self {
        Proxy {
            state: Mutex::new(State::default()),
            to_client: Mutex::new(to_client),
            to_agent: Mutex::new(Some(to_agent)),
            events: Mutex::new(events),
        }
    }

    /// A line from Zed: noted, then given to the agent as it came.
    pub fn from_client(&self, line: &[u8]) {
        if let Some(message) = parse(line) {
            let mut state = self.state.lock().unwrap();
            self.note_client(&mut state, &message);
        }
        self.write_agent(line);
    }

    /// A line from the agent: noted, then given to Zed as it came, unless it
    /// answers a request of the shell's own.
    pub fn from_agent(&self, line: &[u8]) {
        let verdict = match parse(line) {
            Some(message) => self.note_agent(&message),
            None => Verdict::Forward,
        };
        if let Verdict::Forward = verdict {
            self.write_client(line);
        }
    }

    /// Zed closed its end: so does the agent's input, and the agent ends.
    pub fn close_agent(&self) {
        self.to_agent.lock().unwrap().take();
    }

    /// The open threads, as MWT hears them on a new connection.
    pub fn snapshot(&self) -> Vec<Event> {
        let state = self.state.lock().unwrap();
        let mut threads: Vec<_> = state.threads.iter().collect();
        threads.sort_by(|a, b| a.0.cmp(b.0));
        threads
            .into_iter()
            .map(|(id, t)| Event::Opened {
                thread: id.clone(),
                folder: t.folder.clone(),
                title: t.title.clone(),
                working: t.working(),
            })
            .collect()
    }

    pub fn emit(&self, event: Event) {
        let _ = self.events.lock().unwrap().send(event);
    }

    /// Says `text` in `thread` for MWT, which hears `said` or `failed` with
    /// `id`.
    pub fn say(&self, id: &str, thread: &str, text: &str) {
        let mut state = self.state.lock().unwrap();
        if !state.threads.contains_key(thread) {
            drop(state);
            self.emit(Event::Failed {
                id: id.to_string(),
                why: "closed".to_string(),
            });
            return;
        }
        if state.steering {
            let request = own_id(&mut state);
            state.own_requests.insert(
                json::quote(&request),
                OwnRequest::Steer {
                    say: id.to_string(),
                    thread: thread.to_string(),
                    text: text.to_string(),
                },
            );
            drop(state);
            let message = object(vec![
                ("jsonrpc", string("2.0")),
                ("id", string(&request)),
                ("method", string("_session/steering")),
                (
                    "params",
                    object(vec![
                        ("sessionId", string(thread)),
                        ("prompt", text_prompt(text)),
                        (
                            "_meta",
                            object(vec![(
                                "steering",
                                object(vec![("idleBehavior", string("promptRequired"))]),
                            )]),
                        ),
                    ]),
                ),
            ]);
            self.write_agent(message.to_json().as_bytes());
        } else {
            let request = self.begin_prompt(&mut state, thread);
            drop(state);
            self.deliver(thread, text, &request);
            self.emit(Event::Said { id: id.to_string() });
        }
    }

    fn note_client(&self, state: &mut State, message: &Value) {
        let (Some(id), Some(method)) = (
            message.get("id"),
            message.get("method").and_then(Value::as_str),
        ) else {
            return;
        };
        let params = message.get("params");
        let param = |key: &str| {
            params
                .and_then(|p| p.get(key))
                .and_then(Value::as_str)
                .map(str::to_string)
        };
        let request = match method {
            "initialize" => ClientRequest::Initialize,
            "session/new" => ClientRequest::Open {
                thread: None,
                folder: param("cwd").unwrap_or_default(),
            },
            "session/load" | "session/resume" | "session/fork" => ClientRequest::Open {
                thread: if method == "session/fork" {
                    None
                } else {
                    param("sessionId")
                },
                folder: param("cwd").unwrap_or_default(),
            },
            "session/close" => match param("sessionId") {
                Some(thread) => ClientRequest::Close { thread },
                None => return,
            },
            "session/prompt" => match param("sessionId") {
                Some(thread) => {
                    if let Some(t) = state.threads.get_mut(&thread) {
                        t.prompts += 1;
                        if t.prompts == 1 {
                            self.emit(Event::Working {
                                thread: thread.clone(),
                            });
                        }
                    }
                    ClientRequest::Prompt { thread }
                }
                None => return,
            },
            _ => return,
        };
        state.client_requests.insert(id.to_json(), request);
    }

    fn note_agent(&self, message: &Value) -> Verdict {
        let mut state = self.state.lock().unwrap();
        if message.get("method").is_none() {
            let Some(id) = message.get("id").map(Value::to_json) else {
                return Verdict::Forward;
            };
            if let Some(own) = state.own_requests.remove(&id) {
                self.answered_own(state, own, message);
                return Verdict::Keep;
            }
            if let Some(request) = state.client_requests.remove(&id) {
                self.answered_client(&mut state, request, message);
            }
            return Verdict::Forward;
        }
        if message.get("method").and_then(Value::as_str) == Some("session/update") {
            let params = message.get("params");
            let update = params.and_then(|p| p.get("update"));
            if update
                .and_then(|u| u.get("sessionUpdate"))
                .and_then(Value::as_str)
                == Some("session_info_update")
            {
                let thread = params
                    .and_then(|p| p.get("sessionId"))
                    .and_then(Value::as_str);
                let title = update.and_then(|u| u.get("title")).and_then(Value::as_str);
                if let (Some(thread), Some(title)) = (thread, title) {
                    if let Some(t) = state.threads.get_mut(thread) {
                        if t.title.as_deref() != Some(title) {
                            t.title = Some(title.to_string());
                            self.emit(Event::Title {
                                thread: thread.to_string(),
                                title: title.to_string(),
                            });
                        }
                    }
                }
            }
        }
        Verdict::Forward
    }

    fn answered_client(&self, state: &mut State, request: ClientRequest, message: &Value) {
        let ok = message.get("error").is_none();
        match request {
            ClientRequest::Initialize => {
                state.steering = message
                    .at(&["result", "_meta", "steering", "supported"])
                    .and_then(Value::as_bool)
                    == Some(true);
            }
            ClientRequest::Open { thread, folder } if ok => {
                let from_result = message
                    .at(&["result", "sessionId"])
                    .and_then(Value::as_str)
                    .map(str::to_string);
                if let Some(thread) = from_result.or(thread) {
                    let reopened = state.threads.contains_key(&thread);
                    let entry = state.threads.entry(thread.clone()).or_insert(Thread {
                        folder: folder.clone(),
                        title: None,
                        prompts: 0,
                    });
                    if !reopened || entry.folder != folder {
                        entry.folder = folder.clone();
                        self.emit(Event::Opened {
                            thread,
                            folder,
                            title: entry.title.clone(),
                            working: entry.working(),
                        });
                    }
                }
            }
            ClientRequest::Open { .. } => {}
            ClientRequest::Close { thread } => {
                if state.threads.remove(&thread).is_some() {
                    self.emit(Event::Closed { thread });
                }
            }
            ClientRequest::Prompt { thread } => self.prompt_ended(state, &thread),
        }
    }

    fn answered_own(
        &self,
        mut state: std::sync::MutexGuard<'_, State>,
        own: OwnRequest,
        message: &Value,
    ) {
        match own {
            OwnRequest::Prompt { thread } => {
                if let Some(error) = message.get("error") {
                    eprintln!(
                        "mwt-acp: the agent refused MWT's prompt in {thread}: {}",
                        error.to_json()
                    );
                }
                self.prompt_ended(&mut state, &thread);
            }
            OwnRequest::Steer { say, thread, text } => {
                let outcome = message
                    .at(&["result", "outcome"])
                    .and_then(Value::as_str)
                    .unwrap_or("");
                if let Some(error) = message.get("error") {
                    drop(state);
                    let why = error
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("the agent refused it");
                    self.emit(Event::Failed {
                        id: say,
                        why: why.to_string(),
                    });
                    return;
                }
                match outcome {
                    // Joined the running turn, or (an adapter without the
                    // opt-in) started one itself.
                    "injected" | "startedNewTurn" => {
                        drop(state);
                        self.show(&thread, &text);
                        self.emit(Event::Said { id: say });
                    }
                    // No turn runs: the shell starts one, and owns it.
                    "promptRequired" if state.threads.contains_key(&thread) => {
                        let request = self.begin_prompt(&mut state, &thread);
                        drop(state);
                        self.deliver(&thread, &text, &request);
                        self.emit(Event::Said { id: say });
                    }
                    "promptRequired" => {
                        drop(state);
                        self.emit(Event::Failed {
                            id: say,
                            why: "closed".to_string(),
                        });
                    }
                    other => {
                        drop(state);
                        let why = if other.is_empty() {
                            "the agent gave no outcome"
                        } else {
                            other
                        };
                        self.emit(Event::Failed {
                            id: say,
                            why: why.to_string(),
                        });
                    }
                }
            }
        }
    }

    fn prompt_ended(&self, state: &mut State, thread: &str) {
        if let Some(t) = state.threads.get_mut(thread) {
            if t.prompts > 0 {
                t.prompts -= 1;
                if t.prompts == 0 {
                    self.emit(Event::Idle {
                        thread: thread.to_string(),
                    });
                }
            }
        }
    }

    /// Counts a prompt of the shell's own as in flight; its id.
    fn begin_prompt(&self, state: &mut State, thread: &str) -> String {
        let request = own_id(state);
        state.own_requests.insert(
            json::quote(&request),
            OwnRequest::Prompt {
                thread: thread.to_string(),
            },
        );
        if let Some(t) = state.threads.get_mut(thread) {
            t.prompts += 1;
            if t.prompts == 1 {
                self.emit(Event::Working {
                    thread: thread.to_string(),
                });
            }
        }
        request
    }

    /// Shows `text` in Zed and sends it to the agent as the prompt `request`.
    fn deliver(&self, thread: &str, text: &str, request: &str) {
        self.show(thread, text);
        let message = object(vec![
            ("jsonrpc", string("2.0")),
            ("id", string(request)),
            ("method", string("session/prompt")),
            (
                "params",
                object(vec![
                    ("sessionId", string(thread)),
                    ("prompt", text_prompt(text)),
                ]),
            ),
        ]);
        self.write_agent(message.to_json().as_bytes());
    }

    /// Shows `text` in the thread in Zed, as a user message.
    fn show(&self, thread: &str, text: &str) {
        let message = object(vec![
            ("jsonrpc", string("2.0")),
            ("method", string("session/update")),
            (
                "params",
                object(vec![
                    ("sessionId", string(thread)),
                    (
                        "update",
                        object(vec![
                            ("sessionUpdate", string("user_message_chunk")),
                            (
                                "content",
                                object(vec![("type", string("text")), ("text", string(text))]),
                            ),
                        ]),
                    ),
                ]),
            ),
        ]);
        self.write_client(message.to_json().as_bytes());
    }

    fn write_client(&self, line: &[u8]) {
        let mut out = self.to_client.lock().unwrap();
        // Zed gone: the process ends when the agent does.
        let _ = write_line(&mut **out, line);
    }

    fn write_agent(&self, line: &[u8]) {
        let mut slot = self.to_agent.lock().unwrap();
        if let Some(out) = slot.as_mut() {
            if write_line(&mut **out, line).is_err() {
                slot.take();
            }
        }
    }
}

fn own_id(state: &mut State) -> String {
    state.next_own += 1;
    format!("mwt-acp-{}", state.next_own)
}

fn text_prompt(text: &str) -> Value {
    Value::Array(vec![object(vec![
        ("type", string("text")),
        ("text", string(text)),
    ])])
}

fn parse(line: &[u8]) -> Option<Value> {
    let text = std::str::from_utf8(line).ok()?;
    json::parse(text.trim_end()).ok()
}

fn write_line(out: &mut dyn Write, line: &[u8]) -> std::io::Result<()> {
    out.write_all(line)?;
    if !line.ends_with(b"\n") {
        out.write_all(b"\n")?;
    }
    out.flush()
}
