//! The shell's connection to MWT, over the agent channel.
//!
//! One connection, kept open: the first line attaches
//! (`{"command": "attach", "agent": …, "pid": …}`), then one JSON message
//! per line both ways. Up: the [`Event`]s. Down:
//! `{"type": "say", "id": …, "thread": …, "text": …}`.
//!
//! When it drops (MWT restarted, locked or closed), the shell connects
//! again, sooner at first, and sends its open threads again; what happened
//! while it was gone is in that snapshot. MWT never being there only means
//! the threads can't be reached: the shell goes on passing messages.
//!
//! `UNIX-CONNECT:PATH` is opened directly (tests, a development MWT); any
//! other address goes through socat, as for `mwt`: `VSOCK-CONNECT:2:5000`
//! in the VM.

use crate::json::{self, object, string, Value};
use crate::proxy::{Event, Proxy};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::Receiver;
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

pub struct Link {
    pub address: String,
    pub agent: String,
}

struct Connection {
    reader: Box<dyn BufRead + Send>,
    writer: Box<dyn Write + Send>,
    /// Ends the connection when dropped, so the reader stops too.
    closer: Closer,
}

enum Closer {
    Socket(UnixStream),
    Socat(Child),
}

impl Drop for Closer {
    fn drop(&mut self) {
        match self {
            Closer::Socket(stream) => {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
            Closer::Socat(child) => {
                let _ = child.kill();
                let _ = child.wait();
            }
        }
    }
}

impl Link {
    /// Runs for as long as the process: connects, reports, reconnects.
    pub fn run(self, proxy: Arc<Proxy>, events: Receiver<Event>) {
        let mut generation: u64 = 0;
        let mut delay = Duration::from_secs(1);
        loop {
            let started = Instant::now();
            if let Ok(connection) = self.connect() {
                generation += 1;
                self.serve(connection, &proxy, &events, generation);
            }
            // A connection that lasted starts the waiting over.
            if started.elapsed() > Duration::from_secs(30) {
                delay = Duration::from_secs(1);
            }
            thread::sleep(delay);
            delay = (delay * 2).min(Duration::from_secs(30));
        }
    }

    fn serve(
        &self,
        connection: Connection,
        proxy: &Arc<Proxy>,
        events: &Receiver<Event>,
        generation: u64,
    ) {
        let Connection {
            reader,
            mut writer,
            closer: _closer,
        } = connection;

        let attach = object(vec![
            ("command", string("attach")),
            ("agent", string(&self.agent)),
            ("pid", Value::Number(std::process::id().to_string())),
            ("version", string(env!("CARGO_PKG_VERSION"))),
        ]);
        if send(&mut writer, &attach.to_json()).is_err() {
            return;
        }
        // What queued while there was no connection is in the snapshot.
        while events.try_recv().is_ok() {}
        for event in proxy.snapshot() {
            if let Some(line) = event.to_line() {
                if send(&mut writer, &line).is_err() {
                    return;
                }
            }
        }

        let listener = Arc::clone(proxy);
        thread::spawn(move || {
            listen(reader, &listener);
            listener.emit(Event::LinkLost { generation });
        });

        while let Ok(event) = events.recv() {
            match event {
                Event::LinkLost { generation: lost } if lost == generation => return,
                Event::LinkLost { .. } => {}
                event => {
                    if let Some(line) = event.to_line() {
                        if send(&mut writer, &line).is_err() {
                            return;
                        }
                    }
                }
            }
        }
    }

    fn connect(&self) -> Result<Connection, String> {
        if let Some(path) = self.address.strip_prefix("UNIX-CONNECT:") {
            let stream = UnixStream::connect(path).map_err(|e| e.to_string())?;
            let reader = BufReader::new(stream.try_clone().map_err(|e| e.to_string())?);
            let closer = Closer::Socket(stream.try_clone().map_err(|e| e.to_string())?);
            return Ok(Connection {
                reader: Box::new(reader),
                writer: Box::new(stream),
                closer,
            });
        }
        let mut child = Command::new("socat")
            .args(["-", &self.address])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("socat: {e}"))?;
        let writer = child.stdin.take().ok_or("socat has no stdin")?;
        let reader = BufReader::new(child.stdout.take().ok_or("socat has no stdout")?);
        Ok(Connection {
            reader: Box::new(reader),
            writer: Box::new(writer),
            closer: Closer::Socat(child),
        })
    }
}

/// Reads what MWT says until the connection ends.
fn listen(mut reader: Box<dyn BufRead + Send>, proxy: &Proxy) {
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let Some(message) = std::str::from_utf8(&line)
            .ok()
            .and_then(|t| json::parse(t.trim_end()).ok())
        else {
            continue;
        };
        let field = |key: &str| message.get(key).and_then(Value::as_str);
        if field("type") == Some("say") {
            if let (Some(id), Some(thread), Some(text)) =
                (field("id"), field("thread"), field("text"))
            {
                proxy.say(id, thread, text);
            }
        }
    }
}

fn send(writer: &mut Box<dyn Write + Send>, line: &str) -> std::io::Result<()> {
    writer.write_all(line.as_bytes())?;
    writer.write_all(b"\n")?;
    writer.flush()
}
