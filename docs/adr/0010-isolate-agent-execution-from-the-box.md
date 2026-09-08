# Isolate agent execution from the trusted Box

## Decision

`sqrbx-agent` is a Linux host workflow, independent of the normal Box lifecycle,
Managed home, Selection, and runtime options. Pi and the small host execution
adapter belong to the trusted computing base. Model-generated tool requests,
project instructions, dependencies, and all guest processes are untrusted.
A compromised host harness is outside this boundary. The chosen model provider
is an authorized destination for source code and tool results.

Each session starts from committed `HEAD` in an independent Git repository.
It does not share writable Git objects, refs, configuration, or worktree
administration with the source. This replaces the initial linked-worktree
proposal: a linked worktree requires access to common repository metadata,
which is incompatible with protecting that metadata from hostile commands.
Uncommitted and ignored source files are not copied. Session files remain until
explicit discard; the execution environment and guest home are disposable.

Host-owned session identity and reporting state live outside the writable guest
workspace. Paths used for cleanup are derived from validated identity, never
from guest-written paths or Git configuration. Host reports compare against a
trusted baseline and must not execute guest Git hooks, filters, or diff helpers.
Review and import into the original checkout remain explicit human operations.

The first backend is local rootless Podman, explicitly selected with
`--backend podman`. It uses an unprivileged user, all capabilities dropped,
no-new-privileges, a read-only root filesystem, disposable home, and private
SELinux workspace labeling. It bypasses the normal entrypoint because that
entrypoint refreshes and reconciles trusted Box configuration. Normal Box
behavior is unchanged.

Images must already be acquired by immutable digest or local image ID. The
launcher can reuse the recorded Install identity's image, but does not discover
mutable tags or download tools automatically. Optional host Pi SDK dependencies
are installed explicitly from a committed npm lock with lifecycle scripts off.

Networking defaults to `none`. `open` requires an explicit launch option;
`development` is rejected until a backend can enforce a documented policy.
No restricted mode falls back to open networking, and no backend falls back to
a weaker boundary silently.

## Gondolin investigation

Gondolin's current SDK has host-controlled execution, VFS mounts, and HTTP
policy hooks. Its [OCI image builder](https://earendil-works.github.io/gondolin/custom-images/)
can export a digest-pinned Squarebox userspace, but still creates separate
Alpine-derived kernel/initramfs and downloads versioned guest helpers. A
Squarebox OCI digest therefore does not identify the complete guest boot chain.

Gondolin is reserved and fails with an actionable error in this milestone.
Shipping it requires verification and versioning of all boot assets, auditing
the host filesystem provider against escaping links and concurrent mutation,
and live VM/network escape tests. The neutral `exec` backend interface is the
integration point. A nominal wrapper around an upstream example would not be
sufficient evidence of the promised boundary.

## Consequences

Agent mode requires its own host prerequisites and tests; normal installation
does not install host packages or change existing release verification. Linux
is the initial supported host; native Windows, Git Bash, macOS, remote Podman,
and nested invocation from a Box are not supported execution targets.

Disposable homes do not inherit toolchains installed in the Managed home.
Offline projects need dependencies already in the selected image or a separate,
explicit preparation step. CPU/memory/process limits reduce resource abuse;
the writable session directory is not a storage quota. Kernel/runtime flaws,
resource exhaustion, malicious generated changes, and execution after manually
importing those changes remain risks requiring review.
