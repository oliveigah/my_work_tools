//! The first process in the bubble MWT runs microsandbox in.
//!
//! The bubble (bwrap) has its own network with only loopback, so msb has no
//! way out but what this program joins to MWT's sockets:
//!
//! ```text
//! 127.0.0.1:3128  (TCP)       ->  SOCKETS/proxy.sock   msb's --proxy
//! 127.0.0.1:5353  (UDP, TCP)  ->  SOCKETS/dns.sock     msb's --dns-nameserver
//! ```
//!
//! It does five things, in this order:
//!
//! 1. adds a default route into loopback, then gives up every capability for
//!    good. msb gives the VM an IPv4 address only when the kernel can pick a
//!    route to a public address; this one leads nowhere;
//! 2. joins the two loopback ports to the two sockets;
//! 3. runs the `msb create` or `msb start` it was given, and writes how that
//!    went to `SOCKETS/start.out` (exit status on the first line);
//! 4. answers `SOCKETS/control.sock`: `status`, bounded `memory` requests,
//!    and `stop`, which runs `msb stop` and then exits. SIGTERM stops the same way;
//! 5. exits when the VM's process is gone.
//!
//! It runs as process 1 of the bubble's PID namespace (`bwrap --as-pid-1`),
//! so when it exits, however that happens, the kernel ends every other
//! process in the bubble: the VM runs exactly as long as this does. Being
//! process 1, it also collects the processes that end there.
//!
//! One relay per VM: it holds `SOCKETS/relay.lock`, and a second one for the
//! same sockets refuses to start rather than take over the first one's
//! control socket.
//!
//! ```text
//! mwt-relay --sockets DIR --name VM [--no-route] -- MSB ARG...
//! mwt-relay --check
//! ```

use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{Ipv4Addr, Shutdown, TcpListener, TcpStream, UdpSocket};
use std::os::raw::{c_char, c_int, c_long, c_ulong};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{exit, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

#[cfg(not(target_pointer_width = "64"))]
compile_error!("mwt-relay is written for 64-bit Linux");

const PROXY_PORT: u16 = 3128;
const DNS_PORT: u16 = 5353;
const BUFFER: usize = 256 * 1024;
const DNS_IN_FLIGHT: usize = 256;
// Connections joined at once on each TCP port. Past them a new one is
// closed, as one is when no thread can be made for it: the VM sees a
// refusal, and the listener goes on. MWT has a cap of its own, lower, on
// the proxy (`MWTClient.Sandbox.Egress`), so this one is the backstop.
const PROXY_JOINED: usize = 1024;
const DNS_TCP_JOINED: usize = 256;
// Each joined connection has two threads that only move bytes through a
// buffer on the heap.
const THREAD_STACK: usize = 128 * 1024;
const DNS_ANSWER_WITHIN: Duration = Duration::from_secs(6);
const STOP_WITHIN: Duration = Duration::from_secs(90);

static STOP: AtomicBool = AtomicBool::new(false);

extern "C" fn on_terminate(_signal: c_int) {
    STOP.store(true, Ordering::SeqCst);
}

// ---- The few system calls std has no name for ------------------------------

extern "C" {
    fn socket(domain: c_int, kind: c_int, protocol: c_int) -> c_int;
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
    fn prctl(option: c_int, ...) -> c_int;
    fn syscall(number: c_long, ...) -> c_long;
    fn signal(signum: c_int, handler: usize) -> usize;
    fn getuid() -> u32;
    fn waitpid(pid: c_int, status: *mut c_int, options: c_int) -> c_int;
}

const WNOHANG: c_int = 1;

const AF_INET: c_int = 2;
const SOCK_DGRAM: c_int = 2;
const SIOCADDRT: c_ulong = 0x890B;
const RTF_UP: u16 = 0x0001;
const SIGTERM: c_int = 15;
const SIGPIPE: c_int = 13;
const SIG_IGN: usize = 1;
const PR_CAPBSET_DROP: c_int = 24;
const PR_CAP_AMBIENT: c_int = 47;
const PR_CAP_AMBIENT_CLEAR_ALL: c_ulong = 4;
const LINUX_CAPABILITY_VERSION_3: u32 = 0x2008_0522;
#[cfg(target_arch = "x86_64")]
const SYS_CAPSET: c_long = 126;
#[cfg(target_arch = "aarch64")]
const SYS_CAPSET: c_long = 91;

// `struct sockaddr_in`, the size of `struct sockaddr`.
#[repr(C)]
struct SockAddr {
    family: u16,
    port: u16,
    address: u32,
    zero: [u8; 8],
}

// `struct rtentry` from <net/route.h>, as it is on 64-bit Linux.
#[repr(C)]
struct RtEntry {
    rt_pad1: c_ulong,
    rt_dst: SockAddr,
    rt_gateway: SockAddr,
    rt_genmask: SockAddr,
    rt_flags: u16,
    rt_pad2: i16,
    rt_pad3: c_ulong,
    rt_tos: u8,
    rt_class: u8,
    rt_pad4: [i16; 3],
    rt_metric: i16,
    rt_dev: *const c_char,
    rt_mtu: c_ulong,
    rt_window: c_ulong,
    rt_irtt: u16,
}

#[repr(C)]
struct CapHeader {
    version: u32,
    pid: c_int,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct CapData {
    effective: u32,
    permitted: u32,
    inheritable: u32,
}

/// `ip route add default dev lo`: every address has a route, and it leads
/// back here, where nothing answers.
fn add_default_route() -> io::Result<()> {
    let any = || SockAddr {
        family: AF_INET as u16,
        port: 0,
        address: 0,
        zero: [0; 8],
    };
    let device = CString::new("lo").expect("no NUL");

    let route = RtEntry {
        rt_pad1: 0,
        rt_dst: any(),
        rt_gateway: any(),
        rt_genmask: any(),
        rt_flags: RTF_UP,
        rt_pad2: 0,
        rt_pad3: 0,
        rt_tos: 0,
        rt_class: 0,
        rt_pad4: [0; 3],
        rt_metric: 0,
        rt_dev: device.as_ptr(),
        rt_mtu: 0,
        rt_window: 0,
        rt_irtt: 0,
    };

    unsafe {
        let fd = socket(AF_INET, SOCK_DGRAM, 0);
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let result = ioctl(fd, SIOCADDRT, &route as *const RtEntry);
        let error = io::Error::last_os_error();
        close(fd);
        if result < 0 {
            return Err(error);
        }
    }
    Ok(())
}

/// Gives up every capability, and the means to get one back: the bounding
/// set is emptied first, so nothing this process runs (msb is root in the
/// bubble) can hold one either.
fn drop_capabilities() -> Result<(), String> {
    unsafe {
        for capability in 0..64 as c_ulong {
            // Fails for numbers the kernel doesn't know; checked below.
            prctl(
                PR_CAPBSET_DROP,
                capability,
                0 as c_ulong,
                0 as c_ulong,
                0 as c_ulong,
            );
        }
        prctl(
            PR_CAP_AMBIENT,
            PR_CAP_AMBIENT_CLEAR_ALL,
            0 as c_ulong,
            0 as c_ulong,
            0 as c_ulong,
        );

        let header = CapHeader {
            version: LINUX_CAPABILITY_VERSION_3,
            pid: 0,
        };
        let none = [CapData {
            effective: 0,
            permitted: 0,
            inheritable: 0,
        }; 2];
        if syscall(SYS_CAPSET, &header as *const CapHeader, none.as_ptr()) != 0 {
            return Err(format!("capset: {}", io::Error::last_os_error()));
        }
    }

    let status = fs::read_to_string("/proc/self/status").map_err(|e| e.to_string())?;
    let held = |name: &str| -> bool {
        status
            .lines()
            .find(|line| line.starts_with(name))
            .and_then(|line| line.split_whitespace().nth(1))
            .map(|hex| hex.trim_start_matches('0') != "")
            .unwrap_or(true)
    };

    // The bounding set only matters to root, which is what this is in the
    // bubble. Outside one (the tests) an ordinary user keeps it and has
    // nothing to gain from it.
    let root = unsafe { getuid() } == 0;
    if held("CapEff:") || held("CapPrm:") || (root && held("CapBnd:")) {
        return Err("some capability is still held".into());
    }
    Ok(())
}

// ---- Moving bytes ----------------------------------------------------------

fn pump(mut from: impl Read, mut to: impl Write) {
    let mut buffer = vec![0u8; BUFFER];
    loop {
        match from.read(&mut buffer) {
            Ok(0) | Err(_) => break,
            Ok(count) => {
                if to.write_all(&buffer[..count]).is_err() {
                    break;
                }
            }
        }
    }
}

/// A thread for `work`, or the error the system gave. `thread::spawn`
/// panics instead, and a panic here aborts the relay (`panic = "abort"`),
/// the bubble's first process, and with it the VM: a flood of connections
/// must never do that. When it fails, `work` is dropped, and what it held
/// with it.
fn start_thread(work: impl FnOnce() + Send + 'static) -> io::Result<()> {
    thread::Builder::new()
        .stack_size(THREAD_STACK)
        .spawn(work)
        .map(drop)
}

/// One of at most `limit` places, given back when dropped.
struct Slot(Arc<AtomicUsize>);

impl Slot {
    fn take(taken: &Arc<AtomicUsize>, limit: usize) -> Option<Slot> {
        if taken.fetch_add(1, Ordering::SeqCst) < limit {
            Some(Slot(taken.clone()))
        } else {
            taken.fetch_sub(1, Ordering::SeqCst);
            None
        }
    }
}

impl Drop for Slot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Joins a connection msb made to one of MWT's sockets, both ways, passing
/// each side's end of stream on to the other.
fn join(client: TcpStream, path: &Path) {
    let _ = client.set_nodelay(true);
    let Ok(mwt) = UnixStream::connect(path) else {
        // MWT isn't listening: msb sees the connection close, the VM a refusal.
        return;
    };
    let (Ok(client_out), Ok(mwt_out)) = (client.try_clone(), mwt.try_clone()) else {
        return;
    };

    let (done, finished) = std::sync::mpsc::channel();
    let up = start_thread(move || {
        pump(&client, &mwt_out);
        let _ = mwt_out.shutdown(Shutdown::Write);
        let _ = done.send(());
    });
    if up.is_err() {
        // No thread for the other way: both ends close as this returns.
        return;
    }
    pump(&mwt, &client_out);
    let _ = client_out.shutdown(Shutdown::Write);
    let _ = finished.recv();
}

fn serve_tcp(listener: TcpListener, path: PathBuf, limit: usize) {
    serve_tcp_with(listener, path, limit, |work| start_thread(work));
}

/// Joins each connection on `listener` to `path` in a thread `start` makes,
/// at most `limit` at once. One past the limit, or one `start` finds no
/// thread for, is closed, and the listener goes on.
fn serve_tcp_with(
    listener: TcpListener,
    path: PathBuf,
    limit: usize,
    start: impl Fn(Box<dyn FnOnce() + Send>) -> io::Result<()>,
) {
    let joined = Arc::new(AtomicUsize::new(0));

    for client in listener.incoming() {
        let Ok(client) = client else {
            // Out of descriptors, most likely: some close in a moment.
            thread::sleep(Duration::from_millis(50));
            continue;
        };
        let Some(slot) = Slot::take(&joined, limit) else {
            continue;
        };
        let path = path.clone();

        if start(Box::new(move || {
            let _slot = slot;
            join(client, &path);
        }))
        .is_err()
        {
            // The connection and its slot went with the work.
            thread::sleep(Duration::from_millis(50));
        }
    }
}

/// One DNS question to MWT and its answer, framed as DNS over TCP is: two
/// bytes of length, then the message.
fn ask(path: &Path, question: &[u8]) -> io::Result<Vec<u8>> {
    let mut mwt = UnixStream::connect(path)?;
    mwt.set_read_timeout(Some(DNS_ANSWER_WITHIN))?;
    mwt.set_write_timeout(Some(DNS_ANSWER_WITHIN))?;
    mwt.write_all(&(question.len() as u16).to_be_bytes())?;
    mwt.write_all(question)?;
    let mut length = [0u8; 2];
    mwt.read_exact(&mut length)?;
    let mut answer = vec![0u8; u16::from_be_bytes(length) as usize];
    mwt.read_exact(&mut answer)?;
    Ok(answer)
}

fn serve_dns_udp(socket: UdpSocket, path: PathBuf) {
    let in_flight = Arc::new(AtomicUsize::new(0));
    let mut buffer = [0u8; 4096];

    loop {
        let Ok((count, sender)) = socket.recv_from(&mut buffer) else {
            continue;
        };
        // A flood of questions is dropped, as a resolver would.
        let Ok(reply_on) = socket.try_clone() else {
            continue;
        };
        let question = buffer[..count].to_vec();
        let path = path.clone();
        let Some(slot) = Slot::take(&in_flight, DNS_IN_FLIGHT) else {
            continue;
        };

        // No thread for it: dropped, slot and all, like a flood.
        let _ = start_thread(move || {
            let _slot = slot;
            if let Ok(answer) = ask(&path, &question) {
                let _ = reply_on.send_to(&answer, sender);
            }
        });
    }
}

// ---- The VM ----------------------------------------------------------------

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Starting,
    Running,
    Stopped,
}

struct State {
    phase: Phase,
    stop_asked: bool,
    stop_output: String,
    memory: Option<Memory>,
    resize: Option<Resize>,
}

struct Memory {
    minimum: u32,
    maximum: u32,
    target: u32,
}

struct Resize {
    target: u32,
    answer: std::sync::mpsc::Sender<(i32, String)>,
}

fn memory_target(line: &str, memory: &Memory) -> Option<u32> {
    let number = line.strip_prefix("memory ")?;
    if number.is_empty() || !number.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let target = number.parse::<u32>().ok()?;
    (target >= memory.minimum && target <= memory.maximum).then_some(target)
}

/// Whether the VM's process (`msb machine ... --name NAME ...`) is alive.
/// The bubble has its own /proc, so only its own processes are looked at.
fn machine_running(name: &str) -> bool {
    let Ok(entries) = fs::read_dir("/proc") else {
        return false;
    };

    for entry in entries.flatten() {
        let file = entry.file_name();
        let Some(pid) = file.to_str() else { continue };
        if !pid.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }
        let Ok(raw) = fs::read(format!("/proc/{pid}/cmdline")) else {
            continue;
        };
        let words: Vec<&[u8]> = raw.split(|byte| *byte == 0).collect();

        if words.len() > 3
            && words[1] == b"machine"
            && words
                .windows(2)
                .any(|pair| pair[0] == b"--name" && pair[1] == name.as_bytes())
        {
            return true;
        }
    }
    false
}

/// Collects every process that has ended. As process 1 this inherits the
/// bubble's orphans (the VM's process is one, once `msb create` returns).
/// Called only between commands, never while `run` waits for one.
fn reap() {
    let mut status: c_int = 0;
    while unsafe { waitpid(-1, &mut status, WNOHANG) } > 0 {}
}

fn run(program: &str, arguments: &[String]) -> (i32, String) {
    match Command::new(program)
        .args(arguments)
        .stdin(Stdio::null())
        .output()
    {
        Ok(done) => {
            let mut text = String::from_utf8_lossy(&done.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&done.stderr));
            (done.status.code().unwrap_or(-1), text)
        }
        Err(error) => (-1, format!("could not run {program}: {error}\n")),
    }
}

// Run on the main thread, so the orphan reaper cannot collect this child.
// Output goes to a file: reading a full pipe must not defeat the deadline.
fn resize_memory(msb: &str, name: &str, target: u32, sockets: &Path) -> (i32, String) {
    let path = sockets.join("memory.out");
    let Ok(file) = fs::File::create(&path) else {
        return (-1, "could not create memory command output".into());
    };
    let Ok(stderr) = file.try_clone() else {
        return (-1, "could not open memory command output".into());
    };
    let args = [
        "modify",
        name,
        "--memory",
        &format!("{target}M"),
        "--format",
        "json",
    ];
    let mut child = match Command::new(msb)
        .args(args)
        .stdin(Stdio::null())
        .stdout(file)
        .stderr(stderr)
        .spawn()
    {
        Ok(child) => child,
        Err(error) => return (-1, error.to_string()),
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let output = fs::read_to_string(&path).unwrap_or_default();
                let _ = fs::remove_file(&path);
                return (status.code().unwrap_or(-1), output);
            }
            Ok(None) if Instant::now() < deadline && !STOP.load(Ordering::SeqCst) => {
                thread::sleep(Duration::from_millis(20));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                let _ = fs::remove_file(&path);
                return (-1, "memory change interrupted or timed out".into());
            }
        }
    }
}

/// Written aside and renamed, so MWT never reads half of it.
fn write_whole(path: &Path, text: &str) {
    let partial = path.with_extension("part");
    if fs::write(&partial, text).is_ok() {
        let _ = fs::rename(&partial, path);
    }
}

fn serve_control(listener: UnixListener, state: Arc<Mutex<State>>) {
    for connection in listener.incoming().flatten() {
        let state = state.clone();
        // MWT asks again when no thread could be made for this one.
        let _ = start_thread(move || {
            let mut line = String::new();
            let mut reader = BufReader::new(&connection);
            let _ = connection.set_read_timeout(Some(Duration::from_secs(2)));
            let _ = connection.set_write_timeout(Some(Duration::from_secs(2)));
            if reader.by_ref().take(64).read_line(&mut line).is_err() {
                return;
            }
            let mut out = &connection;

            let line = line.trim();
            match line {
                "status" => {
                    let phase = state.lock().unwrap().phase;
                    let word = match phase {
                        Phase::Starting => "starting",
                        Phase::Running => "running",
                        Phase::Stopped => "stopped",
                    };
                    let _ = writeln!(out, "{word}");
                }
                "stop" => {
                    state.lock().unwrap().stop_asked = true;
                    let asked = Instant::now();
                    // The main thread stops the VM; this one reports it.
                    loop {
                        {
                            let state = state.lock().unwrap();
                            if state.phase == Phase::Stopped {
                                let _ = write!(out, "stopped\n{}", state.stop_output);
                                break;
                            }
                        }
                        if asked.elapsed() > STOP_WITHIN + Duration::from_secs(10) {
                            let _ = writeln!(out, "still stopping");
                            break;
                        }
                        thread::sleep(Duration::from_millis(50));
                    }
                }
                "memory" => {
                    let state = state.lock().unwrap();
                    if let Some(memory) = &state.memory {
                        let _ = writeln!(
                            out,
                            "memory {} {} {}",
                            memory.minimum, memory.maximum, memory.target
                        );
                    } else {
                        let _ = writeln!(out, "memory unavailable");
                    }
                }
                _ if line.starts_with("memory ") => {
                    let (answer, receive) = std::sync::mpsc::channel();
                    {
                        let mut state = state.lock().unwrap();
                        let target = state.memory.as_ref().and_then(|m| memory_target(line, m));
                        if state.phase != Phase::Running
                            || state.stop_asked
                            || state.resize.is_some()
                            || target.is_none()
                        {
                            let _ = writeln!(out, "memory change unavailable or outside limits");
                            return;
                        }
                        state.resize = Some(Resize {
                            target: target.unwrap(),
                            answer,
                        });
                    }
                    match receive.recv_timeout(Duration::from_secs(12)) {
                        Ok((0, text)) => {
                            let _ = write!(out, "ok\n{text}");
                        }
                        Ok((_, text)) => {
                            let _ = write!(out, "error\n{text}");
                        }
                        Err(_) => {
                            let _ = writeln!(out, "memory change timed out");
                        }
                    }
                }
                _ => {
                    let _ = writeln!(out, "unknown");
                }
            }
        });
    }
}

fn fail(message: &str) -> ! {
    eprintln!("mwt-relay: {message}");
    exit(2)
}

fn main() {
    let mut sockets: Option<PathBuf> = None;
    let mut name: Option<String> = None;
    let mut route = true;
    let mut check = false;
    let mut command: Vec<String> = Vec::new();
    let mut memory_min: Option<u32> = None;
    let mut memory_max: Option<u32> = None;
    let mut arguments = env::args().skip(1);

    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--sockets" => sockets = arguments.next().map(PathBuf::from),
            "--name" => name = arguments.next(),
            "--memory-min-mib" => memory_min = arguments.next().and_then(|n| n.parse().ok()),
            "--memory-max-mib" => memory_max = arguments.next().and_then(|n| n.parse().ok()),
            "--no-route" => route = false,
            "--check" => check = true,
            "--" => {
                command = arguments.by_ref().collect();
            }
            other => fail(&format!("unknown argument {other}")),
        }
    }

    // Whether a bubble made here lets the relay do its first two steps: MWT
    // asks before it offers to start a VM, so a system that refuses (an
    // AppArmor profile, say) is told apart from one that works.
    if check {
        if let Err(error) = add_default_route() {
            fail(&format!(
                "could not add the default route into loopback: {error}"
            ));
        }
        if let Err(error) = drop_capabilities() {
            fail(&format!("could not give up capabilities: {error}"));
        }
        println!("ok");
        return;
    }

    let (Some(sockets), Some(name)) = (sockets, name) else {
        fail("usage: mwt-relay --sockets DIR --name VM [--no-route] -- MSB ARG...")
    };
    if command.is_empty() {
        fail("nothing to run after --");
    }
    let msb = command[0].clone();
    let memory = match (memory_min, memory_max) {
        (None, None) => None,
        (Some(minimum), Some(maximum))
            if minimum > 0 && maximum >= minimum && maximum <= 524_288 =>
        {
            Some(Memory {
                minimum,
                maximum,
                target: minimum,
            })
        }
        _ => fail("invalid memory limits"),
    };

    // One relay per VM. The lock is held until this process ends.
    let lock = fs::File::create(sockets.join("relay.lock"))
        .unwrap_or_else(|error| fail(&format!("{}: {error}", sockets.display())));
    if lock.try_lock().is_err() {
        eprintln!("mwt-relay: a relay is already running for this VM");
        exit(3);
    }
    std::mem::forget(lock);

    // 1. The route, then no capability left.
    if route {
        if let Err(error) = add_default_route() {
            fail(&format!(
                "could not add the default route into loopback: {error}"
            ));
        }
    }
    if let Err(error) = drop_capabilities() {
        fail(&format!("could not give up capabilities: {error}"));
    }

    unsafe {
        signal(SIGTERM, on_terminate as *const () as usize);
        // A peer closing mid-write is an error to handle, not a reason to die.
        signal(SIGPIPE, SIG_IGN);
    }

    // 2. msb's two ways out.
    let loopback = Ipv4Addr::LOCALHOST;
    let proxy = TcpListener::bind((loopback, PROXY_PORT))
        .unwrap_or_else(|error| fail(&format!("port {PROXY_PORT}: {error}")));
    let dns_tcp = TcpListener::bind((loopback, DNS_PORT))
        .unwrap_or_else(|error| fail(&format!("port {DNS_PORT}: {error}")));
    let dns_udp = UdpSocket::bind((loopback, DNS_PORT))
        .unwrap_or_else(|error| fail(&format!("port {DNS_PORT}/udp: {error}")));

    let proxy_socket = sockets.join("proxy.sock");
    let dns_socket = sockets.join("dns.sock");
    thread::spawn(move || serve_tcp(proxy, proxy_socket, PROXY_JOINED));
    {
        let dns_socket = dns_socket.clone();
        thread::spawn(move || serve_tcp(dns_tcp, dns_socket, DNS_TCP_JOINED));
    }
    thread::spawn(move || serve_dns_udp(dns_udp, dns_socket));

    // 4. (before 3, so MWT can ask how the start is going)
    let state = Arc::new(Mutex::new(State {
        phase: Phase::Starting,
        stop_asked: false,
        stop_output: String::new(),
        memory,
        resize: None,
    }));
    let control_path = sockets.join("control.sock");
    let start_out = sockets.join("start.out");
    let _ = fs::remove_file(&control_path);
    let _ = fs::remove_file(&start_out);
    let control = UnixListener::bind(&control_path)
        .unwrap_or_else(|error| fail(&format!("{}: {error}", control_path.display())));
    {
        let state = state.clone();
        thread::spawn(move || serve_control(control, state));
    }

    // 3. The VM.
    let (status, output) = run(&msb, &command[1..]);
    write_whole(&start_out, &format!("{status}\n{output}"));
    if status != 0 {
        let _ = fs::remove_file(&control_path);
        exit(1);
    }
    state.lock().unwrap().phase = Phase::Running;

    // 5. Until the VM is gone, or a stop is asked for.
    let mut missing = 0;
    loop {
        thread::sleep(Duration::from_millis(250));
        reap();

        if STOP.load(Ordering::SeqCst) || state.lock().unwrap().stop_asked {
            let (_status, mut output) = run(&msb, &["stop".to_string(), name.clone()]);
            let asked = Instant::now();
            while machine_running(&name) && asked.elapsed() < STOP_WITHIN {
                thread::sleep(Duration::from_millis(100));
            }
            if machine_running(&name) {
                output.push_str("The VM did not stop in time; it ends with the bubble.\n");
            }
            {
                let mut state = state.lock().unwrap();
                state.stop_output = output;
                state.phase = Phase::Stopped;
            }
            // Time for the answer to `stop` to go out.
            thread::sleep(Duration::from_millis(300));
            let _ = fs::remove_file(&control_path);
            exit(0);
        }

        let resize = state.lock().unwrap().resize.take();
        if let Some(resize) = resize {
            let result = resize_memory(&msb, &name, resize.target, &sockets);
            if result.0 == 0 {
                if let Some(memory) = state.lock().unwrap().memory.as_mut() {
                    memory.target = resize.target;
                }
            }
            let _ = resize.answer.send(result);
        }

        if machine_running(&name) {
            missing = 0;
        } else {
            missing += 1;
            if missing >= 2 {
                let _ = fs::remove_file(&control_path);
                exit(0);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn memory_requests_accept_only_an_integer_within_the_boot_limits() {
        let memory = Memory {
            minimum: 1024,
            maximum: 3072,
            target: 1024,
        };
        for line in ["memory 1024", "memory 2048", "memory 3072"] {
            assert!(memory_target(line, &memory).is_some());
        }
        for line in [
            "memory 0",
            "memory 1023",
            "memory 3073",
            "memory -1",
            "memory 999999999999999999999",
            "memory 2G",
            "memory 1024 --restart",
            "memory 1024;stop",
            "stop",
            "memory ",
        ] {
            assert!(memory_target(line, &memory).is_none(), "{line}");
        }
    }

    // QA L8: a connection past the limit, or one no thread could be made
    // for, is closed; the listener lives on and joins the next one.
    #[test]
    fn connections_past_the_limit_or_without_a_thread_are_closed_and_the_listener_goes_on() {
        let directory = env::temp_dir().join(format!("mwt-relay-join-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let path = directory.join("proxy.sock");
        let _ = fs::remove_file(&path);
        let mwt = UnixListener::bind(&path).unwrap();
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = listener.local_addr().unwrap().port();

        // The first two find no thread, as when the system has none left.
        let failures = Arc::new(AtomicUsize::new(2));
        {
            let failures = failures.clone();
            let path = path.clone();
            thread::spawn(move || {
                serve_tcp_with(listener, path, 2, move |work| {
                    if failures.load(Ordering::SeqCst) > 0 {
                        failures.fetch_sub(1, Ordering::SeqCst);
                        Err(io::Error::from(io::ErrorKind::WouldBlock))
                    } else {
                        start_thread(work)
                    }
                })
            });
        }

        let connect = || {
            let client = TcpStream::connect((Ipv4Addr::LOCALHOST, port)).unwrap();
            client
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            client
        };
        let closed = |mut client: TcpStream| client.read(&mut [0u8; 1]).unwrap_or(0) == 0;
        let joined = |mut client: TcpStream| {
            let (mut far, _) = mwt.accept().unwrap();
            client.write_all(b"x").unwrap();
            let mut byte = [0u8; 1];
            far.read_exact(&mut byte).unwrap();
            assert_eq!(&byte, b"x");
            (client, far)
        };

        assert!(closed(connect()));
        assert!(closed(connect()));
        assert_eq!(failures.load(Ordering::SeqCst), 0);

        let first = joined(connect());
        let _second = joined(connect());
        // Two are open: a third is past the limit.
        assert!(closed(connect()));

        // One ends, and its place is free again.
        drop(first);
        let deadline = Instant::now() + Duration::from_secs(5);
        mwt.set_nonblocking(true).unwrap();
        let again = loop {
            let mut client = connect();
            client.write_all(b"y").unwrap();
            thread::sleep(Duration::from_millis(50));
            match mwt.accept() {
                Ok((mut far, _)) => {
                    far.set_nonblocking(false).unwrap();
                    let mut byte = [0u8; 1];
                    far.read_exact(&mut byte).unwrap();
                    break byte;
                }
                Err(_) if Instant::now() < deadline => drop(client),
                Err(error) => panic!("not joined again: {error}"),
            }
        };
        assert_eq!(&again, b"y");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn resize_uses_the_fixed_msb_command_and_reports_errors() {
        let directory = env::temp_dir().join(format!("mwt-relay-memory-{}", std::process::id()));
        fs::create_dir_all(&directory).unwrap();
        let msb = directory.join("msb");
        fs::write(&msb, "#!/bin/sh\nprintf '%s\\n' \"$@\"\nexit 7\n").unwrap();
        fs::set_permissions(&msb, fs::Permissions::from_mode(0o700)).unwrap();
        let (code, text) = resize_memory(msb.to_str().unwrap(), "our-vm", 2048, &directory);
        assert_eq!(code, 7);
        assert_eq!(text, "modify\nour-vm\n--memory\n2048M\n--format\njson\n");
        assert!(!directory.join("memory.out").exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
