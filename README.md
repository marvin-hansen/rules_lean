# rules_lean

Bazel rules for [Lean 4](https://lean-lang.org/) and [Mathlib](https://github.com/leanprover-community/mathlib4).

The distinguishing property is that the Mathlib dependency is content-addressed. Every
package, and the prebuilt olean archive, is pinned by sha256 in a committed lockfile and
fetched with `download_and_extract`. Bazel's repository cache and
`--experimental_remote_downloader` can therefore serve the workspace, and it materializes
byte-identically on every machine.

## The problem this solves

A Lake workspace is normally resolved at fetch time, by `lake update` and `lake exe cache
get` running inside `rctx.execute`. Bazel's caches key on sha256, and they cannot see
inside a subprocess. Three consequences follow.

First, every cold output base re-fetches the whole workspace, which for Mathlib means
gigabytes. Second, the resulting tree is not byte-reproducible, because git packfiles
differ from clone to clone. Third, and least obvious: because the tree is not
reproducible, actions consuming it compute different keys on different machines, so Lean
results cannot be shared through a remote cache.

A lockfile changes all three. The figures below come from a Mathlib-based formalization of
about 60 proof files at Lean 4.32.0.

| | before | after |
|---|---|---|
| `bazel build //lean/...`, cold output base | ~20 min | 64.6 s |
| the same, warm | ~20 min | 20 s |
| Lean fetched while building an unrelated target | 10.1 GB | 0 bytes |
| Mathlib modules fetched | 8,639 | 1,918 |
| olean payload | 1,874 MB | 452 MB |

## Install

```python
bazel_dep(name = "rules_lean", version = "0.1.0")
```

### Lake workspace

Use a `workspace` tag when you need Mathlib or any other Lake package.

```python
lake = use_extension("@rules_lean//lean:lake.bzl", "lake")
lake.workspace(
    name = "lake_deps",
    lean_toolchain = "//lean:lean-toolchain",
    lakefile = "//lean:lakefile.toml",
    lake_manifest = "//lean:lake-manifest.json",
    lock = "//lean:lake-lock.json",
    cache_roots = ["Mathlib.Data.Real.Basic"],
)
use_repo(lake, "lake_deps", "lean_dist_4_32_0_toolchains")

register_toolchains("@lean_dist_4_32_0_toolchains//:all")
```

Targets then look like this.

```python
load("@rules_lean//lean:lean.bzl", "lean_test")

# Compiling is the test: a Lean type-check is the proof check.
lean_test(
    name = "smoke_test",
    srcs = ["Smoke.lean"],
    entry = "Smoke.lean",
)
```

Register the `_toolchains` repository rather than `@lake_deps` or a distribution. The
reason is that registering a toolchain makes Bazel fetch the repository holding the
`toolchain()` target, so resolution can evaluate it, and resolution runs for every target
in every build. The `_toolchains` repository downloads nothing, so a build that compiles
no Lean fetches no Lean.

## The lockfile

`lock` points at a committed file. That file pins each Lake package, and the prebuilt
olean archive, by URL and sha256.

```json
{
  "version": 1,
  "lean_toolchain": "leanprover/lean4:v4.32.0",
  "packages": [
    {
      "name": "mathlib",
      "rev": "81a5d257c8e410db227a6665ed08f64fea08e997",
      "url": "https://github.com/leanprover-community/mathlib4/archive/81a5d257….tar.gz",
      "sha256": "86916f6d7a0abee5bec9565f8d1d456ecda937389464acca9f8cea8490c4797b",
      "strip_prefix": "mathlib4-81a5d257…"
    }
  ],
  "oleans": { "url": "https://…/lake-oleans-v4.32.0.tar.gz", "sha256": "…" }
}
```

Every fetch validates the lock against the Lake manifest and the pinned toolchain, and
fails on any disagreement, naming the package and both revisions. Failing rather than
warning is deliberate: a lock disagreeing with the manifest would check your proofs
against a different Mathlib than the manifest names.

One limitation is worth stating plainly. The fast path is all-or-nothing, so a lock with
no `oleans` entry is ignored, with a diagnostic, and the subprocess path runs instead.
That restriction is forced rather than chosen. Mathlib's cache client reads `mathlib/.git`
to pick its cache bucket, and `lake` deletes and re-clones any package whose recorded URL
does not match its checkout. A workspace built from tarballs therefore cannot fall back to
`lake exe cache get`.

### Producing the olean archive

`tools/lean_oleans.py` cuts the artifact set to the transitive import closure of your own
proofs, then packs it reproducibly: the same inputs give the same sha256, whatever the
output path. Three separate defects had to be fixed to get that property — tar
mtime/uid/gid, the gzip header timestamp, and the gzip FNAME field, which stores the
output filename and so made the digest depend on where the file was written.

Host the archive yourself and pin it. It encodes *your* import closure, which is why this
ruleset cannot ship one as a constant: another consumer would silently receive an archive
cut to someone else's imports.

## Tree-shaking

`cache_roots` restricts the Mathlib download to the modules your proofs reach. Each root
expands to its full transitive closure, so a module you import cannot go missing.

The larger lever is usually your own imports rather than this setting. In the
formalization measured above, one import reached 8,639 of Mathlib's 9,450 modules:
`Mathlib.Analysis.Quaternion`, pulled in for four purely algebraic laws. Narrowing it to
`Mathlib.Data.Real.Basic` cut the closure to 1,918. Before that change, tree-shaking
measured as a no-op, because the closure of what was imported and all of Mathlib were the
same set.

## Toolchains and remote execution

Each supported execution platform gets its own `toolchain()`, constrained with
`exec_compatible_with`, and only the selected platform's distribution is fetched.

The constraint matters because a repository rule always runs on the host, so host
detection cannot answer which platform an action will execute on. An unconstrained
declaration matches every execution platform, which sends the host's binary to whatever
worker runs the action. A macOS `lean` on a Linux worker then fails with `Exec format
error`, at execution time, and only under remote execution.

Mathlib oleans, by contrast, are portable: an archive packed on macOS type-checks on Linux
workers. Only the toolchain binary needs per-platform handling.

## Hash policy

Toolchain archives are verified against a recorded sha256. A missing hash fails the build
rather than downloading unverified, because an unverified compiler undermines the point of
checking proofs at all. For a version this ruleset does not know, supply `sha256` per
platform, or opt out explicitly while developing against an unreleased Lean.

## Prior art

Two other Bazel rulesets for Lean exist. Both informed this one.

### [tomato-bazel/rules_lean](https://github.com/tomato-bazel/rules_lean)

MIT, © Matt Marshall. This is the foundation of the ruleset and still most of its code:
the `lean_test`, `lean_emit` and `lean_prebuilt_library` rules, the Lake integration, the
`RulesLean` Lean library for olean and workspace introspection, and the `cache_roots` hook
that the tree-shaking above builds on. Everything described earlier was built on top of
that groundwork rather than in place of it.

The changes then grew to touch the core of the Lake integration and the toolchain model,
which is more than a patch set carries comfortably. A separate ruleset, with its own
version and release cadence, keeps both projects free to move at their own pace. Where a
change here is useful upstream, it is offered back.

### [pulseengine/rules_lean](https://github.com/pulseengine/rules_lean)

An independent implementation from pulseengine, a formal-methods company, carrying an Aeneas/Charon
pipeline for verifying Rust in Lean that neither of the others has. Reading it changed
three decisions here:

- hash enforcement fails closed, rather than warning and downloading unverified;
- the subprocess fallback fetches shallowly, rather than cloning full history;
- CI asserts that each guardrail fires — a missing hash, an unavailable platform, a
  version skew — rather than testing only the happy path.


## License

This project is licensed under the [MIT license](LICENSE).
