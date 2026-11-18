//! MWT's ACP shell. Zed starts it in the agent sandbox's VM in place of an
//! agent's ACP adapter, for the agents **Claude (MWT)** and **Codex (MWT)**;
//! it starts the adapter and passes everything through, and tells MWT which
//! threads are open, so MWT can say something in one. See "Agent threads"
//! in `docs/agent_sandbox.md`.

pub mod json;
pub mod link;
pub mod proxy;
pub mod registry;
pub mod zed;
