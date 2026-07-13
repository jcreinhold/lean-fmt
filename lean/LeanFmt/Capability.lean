/-!
# LeanFmt.Capability

Placeholder capability surface for the `LeanFmt` worker. At the scaffold stage this
exposes only static metadata (name, schema version, package version). The real
`@[export]` command entry points — parse, classify trivia, and compute conservative
edits — are added in the runtime-packaging and frontend prompts, together with the
`lean-rs-worker` streaming/JSON export machinery.
-/

namespace LeanFmt.Capability

/-- Schema identifier of the LeanFmt worker capability contract. -/
def schemaVersion : String := "lean-fmt.capability.v1"

/-- Capability name advertised to the host. -/
def capabilityName : String := "lean-fmt"

/-- Package version, kept in sync with the Rust workspace `version`. -/
def packageVersion : String := "0.1.0"

/-- Static capability metadata rendered as a small JSON object. This is a
    placeholder envelope; the versioned metadata frame is defined alongside the
    real command exports in a later prompt. -/
def metadata : String :=
  "{\"capability\":\"" ++ capabilityName
    ++ "\",\"schema\":\"" ++ schemaVersion
    ++ "\",\"version\":\"" ++ packageVersion ++ "\"}"

end LeanFmt.Capability
