import Foundation

/// The extension a pi session loads to report what it is doing — `OpenCodePresencePlugin`'s
/// counterpart for the fifth backend.
///
/// pi has no hook flags, but its extension API covers every edge the graph reads:
/// `agent_start`/`agent_settled` bracket a run, `tool_call` names what the run is doing,
/// `ui_prompt_start`/`ui_prompt_end` mark a blocking question, and `session_start` hands
/// over the session id a reboot resumes from. All of it writes into the same session-owned
/// label store Claude Code's hooks write to, so `ZmxSessionLauncher.presence(of:)` and
/// `.activity(of:)` read a pi loop with no code of their own.
///
/// **`agent_settled`, not `agent_end`.** pi may auto-retry, compact and retry, or run a
/// queued follow-up after a run ends; reporting idle there would open the delivery window
/// for staged messages while the agent is still going.
///
/// **Usage is re-tallied from the session's entries** rather than accumulated per message,
/// so a resumed session reports what the conversation has spent, not what this process
/// has. Reasoning tokens are already inside `output`.
///
/// Loaded with `-e <path>`, which adds to the user's own extensions. Guarded on
/// `$ZMX_SESSION`, and every write is best-effort. Events verified against pi 0.85.1 with a
/// probe extension, not read off the docs.
enum PiPresenceExtension {
  static func remoteSource(zmxPath: String) -> String {
    source(
      zmxPath: zmxPath,
      sessionsDirectoryExpression: #"join(process.env.HOME ?? "", ".graphcode", "sessions")"#)
  }

  static func source(zmxPath: String, sessionsDirectory: String) -> String {
    source(
      zmxPath: zmxPath,
      sessionsDirectoryExpression: OpenCodePresencePlugin.jsString(sessionsDirectory))
  }

  private static func source(zmxPath: String, sessionsDirectoryExpression: String) -> String {
    """
    // Written by graphcode. Reports what this session is doing, for its card in the graph.
    import { spawnSync } from "node:child_process"
    import { appendFileSync, mkdirSync, writeFileSync } from "node:fs"
    import { join } from "node:path"

    const ZMX = \(OpenCodePresencePlugin.jsString(zmxPath))
    const SESSIONS = \(sessionsDirectoryExpression)
    const PREFIX = \(OpenCodePresencePlugin.jsString(SurfaceRef.zmxSessionPrefix))

    export default function (pi) {
      const session = process.env.ZMX_SESSION
      if (!session || !session.startsWith(PREFIX)) return
      const nodeID = session.slice(PREFIX.length)
      const set = (...labels) => {
        try { spawnSync(ZMX, ["set", session, ...labels], { stdio: "ignore" }) } catch {}
      }
      const encode = (phrase) =>
        phrase.slice(0, 64).replace(/_/g, "_5F").replace(/[^A-Za-z0-9._-]+/g, " ").trim()
          .replace(/ /g, "_20")
      const leaf = (path) => String(path ?? "").split("/").filter(Boolean).pop() ?? ""
      const phrase = (tool, args) => {
        const a = args ?? {}
        const file = a.path
        switch (tool) {
          case "edit": case "write": return file ? "editing " + leaf(file) : "editing files"
          case "read": return file ? "reading " + leaf(file) : "reading"
          case "bash": case "powershell":
            return a.command ? "running " + a.command : "running a command"
          case "grep": return a.pattern ? "searching for " + a.pattern : "searching"
          case "find": return a.pattern ? "looking for " + a.pattern : "looking for files"
          case "ls": return file ? "listing " + leaf(file) : "listing files"
          default: return "using " + tool
        }
      }

      let banked = null
      const bank = (ctx) => {
        const manager = ctx.sessionManager
        const id = manager?.getSessionId?.()
        if (!id || id === banked || !manager?.getSessionFile?.()) return
        banked = id
        try {
          mkdirSync(SESSIONS, { recursive: true })
          const stamp = Math.floor(Date.now() / 1000)
          appendFileSync(join(SESSIONS, nodeID + ".history"), `${stamp} ${id} ${ctx.cwd}\\n`)
          writeFileSync(join(SESSIONS, nodeID + ".id"), id)
        } catch {}
      }
      const tally = (ctx) => {
        let input = 0
        let output = 0
        try {
          for (const entry of ctx.sessionManager?.getEntries?.() ?? []) {
            const message = entry?.type === "message" ? entry.message : null
            if (message?.role !== "assistant" || !message.usage) continue
            const u = message.usage
            input += (u.input ?? 0) + (u.cacheRead ?? 0) + (u.cacheWrite ?? 0)
            output += u.output ?? 0
          }
        } catch {}
        if (input + output > 0) set(`usage=input.${input}_output.${output}`)
      }

      pi.on("session_start", async (_event, ctx) => {
        bank(ctx)
        set("presence=idle", "activity=")
        tally(ctx)
      })
      pi.on("agent_start", async () => { set("presence=busy") })
      pi.on("tool_call", async (event) => {
        set("presence=busy", "activity=" + encode(phrase(event.toolName, event.input)))
      })
      pi.on("ui_prompt_start", async () => { set("presence=awaitingInput") })
      pi.on("ui_prompt_end", async (_event, ctx) => {
        set(ctx.isIdle?.() === false ? "presence=busy" : "presence=idle")
      })
      pi.on("agent_settled", async (_event, ctx) => {
        set("presence=idle", "activity=")
        tally(ctx)
      })
    }
    """
  }
}
