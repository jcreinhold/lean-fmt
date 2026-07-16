module

/- The root deliberately exports no application API. `import all LeanFmt` is reserved for this
package's executable and tests; ordinary downstream imports see an empty module surface. -/
import all LeanFmt.Basic
import all LeanFmt.ArtifactModel
import all LeanFmt.ArtifactStore
import all LeanFmt.Digest
import all LeanFmt.Rules
