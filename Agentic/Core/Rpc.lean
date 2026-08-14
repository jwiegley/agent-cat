import Lean.Data.Json

/-!
# JSON-RPC 2.0, line-delimited: the frames both protocols in this package share

`Agentic/Core/Acp.lean` is a **client** of a child process and
`Agentic/Core/Mcp.lean` is a **server** on this process's own stdio, but they
speak the same wire format — one JSON value per line, in the three shapes
JSON-RPC 2.0 admits — so the decoder and the four encoders live here and are
written once.

**This module makes no claim about meaning.** It contains no `Ω`, no `Q`, no
`Dlg` and no `Plan`, and it imports nothing from this package; like `Acp`, it
*cannot* say anything about worlds, questions or answers even by accident. What
a run means is settled in `Agentic/Core/Exec.lean` and
`Agentic/Core/Certify.lean`.

**What is proved here is nothing, and the reason is stated rather than hidden.**
`Json.parse` and `Json.compress` are string-level functions built from
`String.splitOn`-style well-founded recursion, which does not reduce in the
kernel; `decide` gets stuck on every equation one would want (measured, not
assumed). `native_decide` would close them and is forbidden — it adds
`Lean.ofReduceBool` to the axiom set, and `Agentic/Core/Certify.lean`'s
`#guard_msgs` pins must keep elaborating. So the round trips below are `#guard`
commands: they are evaluated at elaboration time, they fail the build if they
are false, and they add no axiom to any declaration because they declare
nothing. That is weaker than a theorem and is labelled as such.

**The trust boundary this module adds.** One assumption, discharged by nothing:
that a line of bytes is one complete JSON value. Framing is the newline, as in
both protocols; a peer that writes a bare newline inside a string literal has
desynchronized the stream and this decoder will report a parse error rather than
silently resynchronize.
-/

namespace Agentic.Core.Rpc

open Lean (Json)

/-! ## The three shapes a line can have -/

/-- `[[Msg]]` = one decoded line of the wire: JSON-RPC 2.0 admits exactly three
shapes, and this is them.

The value represents *what arrived*, not what it means. Ids stay raw `Json`
rather than `Nat` because JSON-RPC permits string ids and a request from the
peer must be answered with the id it chose, unchanged; our own ids are always
numeric, which is why matching a response needs only `getNat?`. Note that the
peer's ids and ours are drawn from *different* counters that may both start at
zero: what tells an inbound request from the response to our own request `0` is
the presence of `method`, which is why it is tested first. -/
inductive Msg where
  /-- A reply to one of our requests; `Except` is the error/result split. -/
  | response (id : Json) (payload : Except Json Json)
  /-- A request *from* the peer, which must be answered with the same id. -/
  | request (id : Json) (method : String) (params : Json)
  /-- A notification, which must not be answered. -/
  | notification (method : String) (params : Json)

/-- Decode one line. Failure is an `Except` here and becomes a protocol error or
an `IO` error at the call site, where the line is still in hand. -/
def Msg.ofLine (line : String) : Except String Msg := do
  let j ← Json.parse line
  match j.getObjVal? "method" with
  | .ok mj =>
    let method ← mj.getStr?
    let params := j.getObjValD "params"
    match j.getObjVal? "id" with
    | .ok id => return .request id method params
    | .error _ => return .notification method params
  | .error _ =>
    match j.getObjVal? "id" with
    | .error _ => throw "line is neither a request, a notification nor a response"
    | .ok id =>
      match j.getObjVal? "error" with
      | .ok e => return .response id (.error e)
      | .error _ => return .response id (.ok (j.getObjValD "result"))

/-! ## The four frames one can write

Each is a `Json` value and not a `String`: the newline is added by whoever owns
the stream, so that a writer cannot forget the flush and a test can inspect the
value instead of parsing it back. -/

/-- A request: an id, a method, and params. -/
def request (id : Json) (method : String) (params : Json) : Json :=
  Json.mkObj [("jsonrpc", Json.str "2.0"), ("id", id), ("method", Json.str method),
    ("params", params)]

/-- A notification: a method and params, and no id, so no reply is expected. -/
def notification (method : String) (params : Json) : Json :=
  Json.mkObj [("jsonrpc", Json.str "2.0"), ("method", Json.str method), ("params", params)]

/-- A successful reply, carrying the id of the request it answers. -/
def result (id : Json) (payload : Json) : Json :=
  Json.mkObj [("jsonrpc", Json.str "2.0"), ("id", id), ("result", payload)]

/-- A failed reply: **a protocol error**, which is a different thing from a call
that ran and reported a problem. The distinction is load-bearing in
`Agentic/Core/Mcp.lean`: a request naming a tool that does not exist is this,
and a tool that ran and found the source ill-typed is a *result* carrying
`isError`, because the second is actionable by the caller and the first is
not. -/
def errorFrame (id : Json) (code : Int) (message : String) : Json :=
  Json.mkObj [("jsonrpc", Json.str "2.0"), ("id", id),
    ("error", Json.mkObj [("code", (code : Json)), ("message", Json.str message)])]

/-! ## The codes, by their names in the specification -/

/-- Invalid JSON was received. -/
def parseError : Int := -32700
/-- The JSON sent is not a valid request object. -/
def invalidRequest : Int := -32600
/-- The method does not exist, or is not available on this peer. -/
def methodNotFound : Int := -32601
/-- The method exists, but the params are wrong. -/
def invalidParams : Int := -32602
/-- Something went wrong inside the peer. -/
def internalError : Int := -32603

/-! ## Round trips, pinned rather than proved

Each `#guard` writes a frame, compresses it, decodes it, and asks whether what
came back is the shape that went out. They run at elaboration time and fail the
build when they are false. See the module header for why these are not
theorems. -/

/-! A request survives the round trip as a request, with its method. -/
#guard (match Msg.ofLine (request (Json.num 7) "tools/call" (Json.mkObj [])).compress with
        | .ok (.request _ m _) => m == "tools/call"
        | _ => false)

/-! A notification survives as a notification: no id, so no reply. -/
#guard (match Msg.ofLine (notification "notifications/initialized" (Json.mkObj [])).compress with
        | .ok (.notification m _) => m == "notifications/initialized"
        | _ => false)

/-! A result survives as a successful response. -/
#guard (match Msg.ofLine (result (Json.num 7) (Json.mkObj [])).compress with
        | .ok (.response _ (.ok _)) => true
        | _ => false)

/-! An error frame survives as a failed response, and is *not* read as a result:
the split that tells "the peer refused" from "the peer answered" is the one a
caller acts on. -/
#guard (match Msg.ofLine (errorFrame (Json.num 7) methodNotFound "nope").compress with
        | .ok (.response _ (.error _)) => true
        | _ => false)

/-! A line that is none of the three is a parse failure and not a guess. -/
#guard (match Msg.ofLine "{\"jsonrpc\":\"2.0\"}" with
        | .error _ => true
        | _ => false)

end Agentic.Core.Rpc
