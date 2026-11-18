// Panes marked data-keep-scroll come back scrolled where they were left
// when their tool is opened again; the server keeps the rest of a tool's
// place (MWTClientWeb.Hooks.Places).
//
// A position is kept per page and pane id for the browser session. After a
// tool opens, a pane whose content arrives late (read in the background)
// is scrolled as soon as it is long enough, for a few seconds, unless the
// reader scrolls or clicks first.

const PANE = "[data-keep-scroll][id]"
const WAIT_MS = 5000

const prefix = () => `mwt:scroll:${location.pathname}#`

// Pane id -> the scrollTop it is to come back to.
let pending = new Map()
let deadline = 0
let observer = null

const stop = () => {
  pending.clear()
  observer?.disconnect()
}

const apply = () => {
  if (performance.now() > deadline) return stop()

  for (const [id, top] of pending) {
    const pane = document.getElementById(id)
    if (!pane?.matches(PANE)) continue

    pane.scrollTop = top
    // Short of it, the content isn't all there yet: try again when it grows.
    if (Math.abs(pane.scrollTop - top) <= 1) pending.delete(id)
  }

  if (pending.size === 0) stop()
}

const restore = () => {
  stop()
  const start = prefix()

  for (let i = 0; i < sessionStorage.length; i++) {
    const key = sessionStorage.key(i)
    const top = Number(sessionStorage.getItem(key))
    if (key.startsWith(start) && top > 0) pending.set(key.slice(start.length), top)
  }

  deadline = performance.now() + WAIT_MS
  apply()

  if (pending.size > 0) {
    observer ||= new MutationObserver(apply)
    observer.observe(document.body, {childList: true, subtree: true})
  }
}

export function installKeepScroll() {
  // Scroll events don't bubble, so they are caught on the way down. A pane
  // still waiting for its position doesn't record the one it passes by.
  document.addEventListener("scroll", event => {
    const pane = event.target
    if (pane instanceof Element && pane.matches(PANE) && !pending.has(pane.id)) {
      sessionStorage.setItem(prefix() + pane.id, String(Math.round(pane.scrollTop)))
    }
  }, true)

  for (const type of ["wheel", "touchstart", "keydown", "pointerdown"]) {
    window.addEventListener(type, stop, {capture: true, passive: true})
  }

  // A tool opened (live navigation) or the page loaded; moving within a
  // tool (a patch) leaves its panes as they are.
  window.addEventListener("phx:page-loading-stop", ({detail}) => {
    if (detail?.kind === "redirect" || detail?.kind === "initial") restore()
  })
}
