import Lean.Data.Json

/-!
# LeanFmt.Capability

The `lean-rs-worker` capability surface for the `LeanFmt` worker: a shared-library
capability (built via `LeanLib.sharedFacet`) that a Lean-linked worker child loads,
exposing worker commands as `@[export]` functions rather than a subprocess dispatch
loop.

At this stage the capability exposes two request/response commands:

* `lean_fmt_metadata` — returns the static capability identity (name, schema, version).
* `lean_fmt_doctor` — a self-check that parses the capability's own metadata envelope
  and reports whether the capability is loaded and responding.

Both are plain `String → IO String` exports, matching the request/response export
pattern (e.g. lean-dup's `version`). They deliberately do not depend on the
`lean-rs` interop streaming shims: those are pulled in by the first *streaming*
export (the source-snapshot frontend), not by these identity/self-check commands.
The Rust worker child registers each export as a JSON command on the host side.
-/

namespace LeanFmt.Capability

open Lean

/-- Schema identifier of the LeanFmt worker capability contract. -/
def schemaVersion : String := "lean-fmt.capability.v1"

/-- Capability name advertised to the host. -/
def capabilityName : String := "lean-fmt"

/-- Package version, kept in sync with the Rust workspace `version`. -/
def packageVersion : String := "0.1.0"

/-- Static capability metadata as a JSON object. -/
def metadataJson : Json :=
  Json.mkObj
    [ ("capability", Json.str capabilityName)
    , ("schema", Json.str schemaVersion)
    , ("version", Json.str packageVersion)
    ]

/-- Static capability metadata rendered as a compact JSON string. -/
def metadata : String := metadataJson.compress

/--
Request/response export returning the static capability metadata.

The request payload is ignored: metadata is fixed capability identity. Returned
verbatim so the Rust worker client deserializes it unchanged.
-/
@[export lean_fmt_metadata]
def metadataCommand (_requestJson : String) : IO String :=
  pure metadata

/--
Request/response export performing a capability self-check.

Parses the capability's own metadata envelope and reports whether it is
well-formed, which confirms the shared library loaded and the export is callable
(the round-trip a worker uses to prove the capability is live).
-/
@[export lean_fmt_doctor]
def doctorCommand (_requestJson : String) : IO String := do
  let metadataValid := (Json.parse metadata).toOption.isSome
  let result :=
    Json.mkObj
      [ ("capability", Json.str capabilityName)
      , ("schema", Json.str schemaVersion)
      , ("version", Json.str packageVersion)
      , ("ok", Json.bool metadataValid)
      , ("metadata_valid", Json.bool metadataValid)
      ]
  pure result.compress

end LeanFmt.Capability
