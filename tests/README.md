# tests

Offline tests. None of them need a cluster, a Helm repository or Azure; they run
from a clone and are part of `scripts/validate.sh`.

```bash
tests/run-all.sh              # everything that runs without extra binaries
tests/run-all.sh --against-cli   # also compare every flag with the installed CLIs
```

| Suite | What it covers | Requires |
|---|---|---|
| `cli-flags/` | Flags the pinned CLI version no longer accepts, in shell scripts, WorkflowTemplates and Markdown | python3 (PyYAML) |
| `helm4/` | `workflows/scripts/helm-addons.sh` end to end against a Helm 4 CLI | python3, jq, yq (mikefarah) |
| `shared-lib/` | The shared library block in `workflows/scripts/common.sh`: identical to the copy in tpg-aks-infra, retries, pod watch | jq |
| `sync-engine/` | The Argo CD sync engine (`app_sync_wait` in `workflows/scripts/lib.sh`) against a scripted Argo CD API | jq |
| `rollout/` | `rolloutMode` of tpg-day0 and tpg-upgrade (`workflows/scripts/plan-batches.sh`) | jq |

`tpg-aks-infra/tests/verify/run.sh` covers `scripts/steps/60-verify.sh` and its
summary, and uses the stubs in `helm4/bin`, so both repositories test against
the same fakes. `tpg-aks-infra/tests/shared-lib/run.sh` is the same file as
`shared-lib/run.sh` here.

## cli-flags

A removed CLI flag is invisible to yamllint, shellcheck and kubeconform. It
fails at run time, inside a workflow step, halfway through a deployment. That is
how `helm list -a` reached the fleet: the workflow tools image moved to
`alpine/k8s:1.35.8`, which ships Helm 4, and Helm 4 removed `-a`.

`check_cli_flags.py` reads the commands out of the repository and applies
`rules.yaml`, which lists per tool and subcommand the flags that are gone or
renamed, why, and what to write instead. Add a rule whenever a pinned image
moves to a new major CLI version, and add a line to
`fixtures/violations.sh` for it: `run.sh` asserts that every rule fires exactly
once there and that nothing fires in `fixtures/clean.md`, so a rule that stops
matching, or one that matches too much, fails the suite.

`--against-cli` goes further and asks every installed binary for its own flags
(`<tool> <subcommand> --help`), then reports each flag the repository uses that
the binary does not know. It catches changes nobody has written a rule for yet.
Tools that are not installed are skipped, so it is safe to run anywhere.

## helm4

`bin/helm` and `bin/kubectl` are stubs. The helm stub parses flags the way Helm
4 does: `helm list -a` exits 1 with `unknown shorthand flag: 'a'`, exactly as
the real binary does in the tools image, and `helm registry login` rejects a
host with a path. Cluster and release state come from JSON files, so the add-on
pre-check can be driven through all of its outcomes: `DRY_RUN`, `UP_TO_DATE`,
`SKIPPED_EXISTS`, `SKIPPED_NEWER`, `REUSED_EXISTING` and `BLOCKED`.

The last case in the suite runs `helm list -a` against the stub and fails if it
is accepted, so a green suite cannot mean "the stub accepts anything".

## shared-lib

`workflows/scripts/common.sh` (tpg-fleet) and `scripts/lib/common.sh`
(tpg-aks-infra) carry the same block, between `# >>> tpg-shared >>>` and
`# <<< tpg-shared <<<`: the retrying `kubectl`, `helm`, `az` and `argocd`
wrappers (`tpg_retry`), `pods_watch`, the Helm release pre-check and install
(`hr_*`) and `monitoring_flowing`. The suite

1. fails when the two copies differ (edit one, then run `tests/shared-lib/sync.sh`
   in that repository to copy the block to the other);
2. drives `tpg_retry` with stub commands: a transient API error is retried and
   the output appears once; a NotFound or a `helm --wait` timeout is not
   retried; `-f -` input is given to every attempt, while a command that does
   not read standard input leaves the caller's loop input alone; a `create` that
   reached the server before the connection dropped counts as created;
   `kubectl exec` is never retried; the retry log does not print arguments;
3. drives `pods_watch` with pod lists: ready pods pass,
   `CreateContainerConfigError` fails at once, `CrashLoopBackOff` is tolerated
   for `POD_WATCH_PERSIST_SECONDS` (60) and then fails, an unschedulable pod fails
   after `POD_WATCH_PENDING_SECONDS` (300) with the scheduler's message, an init
   container failure is named, and the failure prints the pod's events and logs
   (with `--previous` for a restarted container).

## sync-engine

The workflows sync Applications through `app_sync_wait`. The suite scripts the
Argo CD API responses and proves that the previous operation's `Succeeded` is
not taken as the answer, that an admission webhook denial fails at once with
`SYNC_REJECTED` after one request (the upgrade used to record `SUCCEEDED`
there), that a transient error is synced again, that an Application that stays
OutOfSync fails with `SYNC_DRIFT`, and that a stuck operation ends with
`SYNC_TIMEOUT`.

## rollout

`plan-batches.sh` with a stub `lib.sh`: `canary` (the wave-0 cluster alone,
then batches of `maxParallel` per wave), `batches` (no canary) and `all` (one
batch), and an unknown mode fails.
