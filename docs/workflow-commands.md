# Workflow command reference

Every tpg operation is an Argo Workflows `WorkflowTemplate` in the `argo` namespace on the hub. You start a run with the **argo CLI** (`argo submit --from workflowtemplate/<name>`). Argo CD does not start workflows: the workflows call the Argo CD API to refresh and sync Applications. The **argocd CLI** commands at the end of this page show the same sync steps, for manual runs and troubleshooting.

Mandatory inputs have no default. A run without them fails in its first step (`validate`) and lists every missing or invalid input, including the registered cluster names.

## Contents

1. [Set up the CLIs](#1-set-up-the-clis)
2. [Common inputs and conventions](#2-common-inputs-and-conventions)
3. [tpg-day0](#3-tpg-day0)
4. [tpg-upgrade](#4-tpg-upgrade)
5. [tpg-scale-instance](#5-tpg-scale-instance)
6. [tpg-delete-apps](#6-tpg-delete-apps)
7. [tpg-delete-instance](#7-tpg-delete-instance)
8. [tpg-helm-addons](#8-tpg-helm-addons)
9. [tpg-backup](#9-tpg-backup)
10. [tpg-backup-retention](#10-tpg-backup-retention)
11. [tpg-restore](#11-tpg-restore)
12. [tpg-rotate-credential](#12-tpg-rotate-credential)
13. [Follow, approve, stop and clean up runs](#13-follow-approve-stop-and-clean-up-runs)
14. [argocd CLI: the sync steps behind the workflows](#14-argocd-cli-the-sync-steps-behind-the-workflows)

---

## 1. Set up the CLIs

```bash
# Kubeconfig written by tpg-aks-infra/scripts/run.sh (context aks-tpg-hub)
export KUBECONFIG=~/src/tpg-aks-infra/.work/kubeconfig
export ARGO_NAMESPACE=argo            # every command below then works without -n argo

argo version
argo template list
```

To use the Argo Workflows server instead of the Kubernetes API (for example from a laptop without cluster access), see `tpg-aks-infra/docs/README-argo-on-aks.md` and set `ARGO_SERVER`, `ARGO_HTTP1=true`, `ARGO_SECURE=true` and `ARGO_TOKEN`.

```bash
# argocd CLI against the hub (port-forward works without a public UI)
kubectl --context aks-tpg-hub -n argocd port-forward svc/argocd-server 18080:443 >/dev/null 2>&1 &
argocd login localhost:18080 --username admin --insecure --grpc-web \
  --password "$(kubectl --context aks-tpg-hub -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
```

## 2. Common inputs and conventions

| Input | Values | Used by |
|---|---|---|
| `clusters` | `aks-tpg-poc-01,aks-tpg-poc-02` or `all` (every registered cluster) | day0, upgrade, delete-apps, helm-addons, backup, restore |
| `cluster` | One registered cluster | scale, delete-instance |
| `pushMode` | `direct`: push the `clusters/fleet.yaml` change to the fleet branch. `pr`: push a branch, open a GitHub pull request and continue once it is merged (`prTimeoutSeconds`, default 3600) | day0, upgrade, scale, delete-apps, delete-instance |
| `dryRun` | `true`: validate and record the plan; change nothing | day0, upgrade, scale, delete-apps, helm-addons |
| `rolloutMode` | `canary` (default): the wave-0 cluster alone, then the other waves in batches of `maxParallel`. `batches`: no canary, batches of `maxParallel` in wave order. `all`: every selected cluster in one batch | day0, upgrade |
| Operator version | `v4.5.0` (`4.5.0` is accepted) | day0 `operatorVersion`, upgrade `targetVersion` |
| Postgres version | `postgres-17.6` (`17.6` is accepted); must exist in `kubectl get postgresversion` | day0 `postgresVersion`, upgrade `targetVersion` |

- Put values that contain commas, spaces or JSON in single quotes.
- `-p name=value` sets one input. `--parameter-file inputs.yaml` reads several from a file (examples in each section).
- `--watch` follows the run in the terminal. Without it, the command prints the workflow name.
- `--name` or `--generate-name` sets the workflow name, which is also the results ConfigMap `tpg-run-<name>`.
- Every run ends with a report (exit handler). `argo logs @latest -c main | sed -n '/tpg run report/,$p'` prints it again.
- While a step waits for pods (Helm releases, the operator, instances, upgrades, scale, restore), it prints the pod table of the namespace every 5 seconds and stops as soon as a pod cannot start. The failure reason is `POD_<REASON>` (for example `POD_CRASHLOOPBACKOFF`, `POD_CREATECONTAINERCONFIGERROR`, `POD_UNSCHEDULABLE`), followed in the log by the pod's status, events and the logs of the failing container. `CreateContainerConfigError`, `CreateContainerError`, `InvalidImageName` and `RunContainerError` fail at once; `CrashLoopBackOff`, `ImagePullBackOff`/`ErrImagePull`, `Error` and `OOMKilled` after 60 seconds; an unschedulable or Pending pod after 5 minutes.
- Transient API errors (timeouts, connection resets, HTTP 429/502/503/504) of `kubectl`, `helm`, `az` and the Argo CD API are retried up to 5 times with 5, 10, 20 and 40 seconds between attempts (`TPG_RETRY_ATTEMPTS`, `TPG_RETRY_DELAY`); the log shows `<tool> <verb>: transient error (attempt n/5), retrying in Ns: <error>`.
- Argo CD syncs are made at the fleet commit the run pushed; a sync the API server rejects (admission webhook, invalid field) fails the step at once with Argo CD's message.

---

## 3. tpg-day0

Writes the inputs to `clusters/fleet.yaml`, pre-checks every selected cluster, installs cert-manager (and the standalone monitoring agent) as Helm releases, then syncs the operator and instance Applications: by default wave 0 alone first, then the other waves in batches of `maxParallel` (`rolloutMode`).

The operator step waits until the Postgres CRDs are Established and the operator Deployment is available on the target, then hard-refreshes the Application, so it does not wait for the Argo CD cache. An instance is ready when the Postgres resource reports `Running` and its StatefulSets are ready; Argo CD shows it Progressing until then.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `clusters` | yes | | Registered clusters or `all` |
| `instances` | yes | | Instances to deploy on every selected cluster (namespace `pg-<instance>`) |
| `highAvailability` | yes | | `true` (primary and standby, plus `readReplicas`) or `false` (single node) |
| `operatorVersion` | yes | | Operator chart version |
| `postgresVersion` | yes | | PostgresVersion name |
| `pushMode` | yes | | `direct` or `pr` |
| `readReplicas` | no | `1` | Read replicas when `highAvailability=true` (0 to `maxReadReplicas`, default 3) |
| `storageSize`, `walStorageSize` | no | template (`20Gi`, `10Gi`) | Volume sizes |
| `storageClass` | no | template (`tpg-data-retain`) | StorageClass |
| `cpu`, `memory` | no | template (requests 1/2Gi, limits 2/4Gi) | Request and limit per Postgres pod |
| `backupSchedule` | no | `fleet` | `fleet`: included in `tpg-backup-full` and `tpg-backup-incr`; `none`: excluded |
| `installAddons` | no | `true` | Install or upgrade cert-manager (and the standalone monitoring agent) |
| `monitoringOption` | no | `tpg-settings` | Override: `none`, `azure`, `standalone` |
| `backupEnableSSL` | no | `false` | `enableSSL` of the instances' `PostgresBackupLocation`: `false` uses HTTP to Azure Blob (the storage account must accept HTTP, Terraform `backup_storage_https_only = false`), `true` uses HTTPS |
| `maxParallel` | no | `2` | Clusters per batch after the canary |
| `rolloutMode` | no | `canary` | `canary`, `batches` or `all` (section 2) |
| `dryRun` | no | `false` | Show the `fleet.yaml` change and run the pre-check only |
| `syncTimeoutSeconds`, `prTimeoutSeconds` | no | `1800`, `3600` | Timeouts |

The pre-check reports a cluster `BLOCKED` when it finds a foreign operator or CRDs, an instance name already in use, a Postgres version that does not exist, or a data pool that cannot hold an HA instance (`PGDATA_POOL_NOT_HA_CAPABLE`: `highAvailability=true` needs 3 Ready nodes across zones 1, 2 and 3 in the pool labelled `tpg.fleet/pool=postgres`). A blocked cluster is not changed and the run continues with the others.

A version that differs from one already declared in `fleet.yaml` fails the run (`FLEET_CONFLICT`): use `tpg-upgrade` for that.

```bash
# 1. Dry run on every registered cluster: validation, fleet.yaml diff, pre-check
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 \
  -p pushMode=direct -p dryRun=true --watch

# 2. Deploy orders-db with HA and 2 read replicas on all clusters, direct push
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true -p readReplicas=2 \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct --watch

# 3. Two single-node instances on one new cluster, sized, reviewed through a pull request
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-04 -p instances=billing-db,reporting-db -p highAvailability=false \
  -p operatorVersion=4.5.0 -p postgresVersion=17.6 \
  -p storageSize=100Gi -p walStorageSize=20Gi -p cpu=2 -p memory=8Gi \
  -p pushMode=pr -p prTimeoutSeconds=7200 --watch

# 4. Lab instance excluded from scheduled backups; cert-manager already installed
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=aks-tpg-poc-03 -p instances=scratch-db -p highAvailability=false \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p backupSchedule=none -p installAddons=false --watch

# 5. Three batches of 3 clusters after the canary, longer sync timeout
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p maxParallel=3 -p syncTimeoutSeconds=3600 --watch

# 6. Every cluster at once (no canary), backups over HTTPS
argo submit --from workflowtemplate/tpg-day0 \
  -p clusters=all -p instances=orders-db -p highAvailability=true \
  -p operatorVersion=v4.5.0 -p postgresVersion=postgres-17.6 -p pushMode=direct \
  -p rolloutMode=all -p backupEnableSSL=true --watch
```

With a parameter file:

```yaml
# day0-orders.yaml
clusters: aks-tpg-poc-01,aks-tpg-poc-02,aks-tpg-poc-03
instances: orders-db
highAvailability: "true"
readReplicas: "1"
operatorVersion: v4.5.0
postgresVersion: postgres-17.6
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-day0 --parameter-file day0-orders.yaml --watch
```

---

## 4. tpg-upgrade

Upgrades the operator (`component=operator`) or Postgres instances (`component=postgres`), canary first, and writes the new version to `clusters/fleet.yaml`.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `component` | yes | | `operator` or `postgres` |
| `targetVersion` | yes | | Operator: `v4.5.1`; Postgres: `postgres-17.6` |
| `clusters` | yes | | Registered clusters or `all` |
| `pushMode` | yes | | `direct` or `pr` |
| `instances` | yes for `postgres` | | Instances or `all`; not allowed for `operator` |
| `preUpgradeBackup` | no | `true` | Full backup of each affected instance first |
| `allowMajor` | no | `false` | Allow major Postgres upgrades; pauses for approval before every batch after the canary |
| `maxParallel` | no | `1` | Clusters per batch after the canary |
| `rolloutMode` | no | `canary` | `canary`, `batches` or `all` (section 2). With `allowMajor=true`, the approval pause comes before every batch after the first |
| `dryRun` | no | `false` | Record the planned upgrade (minor or major, current and target) per target |
| `timeoutSeconds`, `prTimeoutSeconds` | no | `1800`, `3600` | Per cluster (operator) or per instance (Postgres) |

Minor or major is detected per instance. Downgrades fail. Instances not selected are reported as `SKIPPED_NOT_SELECTED`.

A Postgres upgrade of one instance runs in this order:

1. Full backup (`preUpgradeBackup=true`).
2. `PostgresVersionUpgrade` created on the target and followed with the instance pods printed every 5 seconds; `Failed` or `PreCheckFailed` ends the instance as `FAILED` with the operator's message.
3. The instance is `Running` with the target `status.dbVersion` (`DB_VERSION_MISMATCH` otherwise).
4. The workflow waits up to 5 minutes for the operator to set `spec.postgresVersion.name` to the target (each poll is logged); if it does not, it logs that and goes on, because Argo CD ignores that field.
5. The version is written to `clusters/fleet.yaml`, pushed, and the Application is synced at that commit.
6. `SUCCEEDED` only when the Application is Synced. Otherwise the instance is `FAILED` with the sync reason (`SYNC_REJECTED`, `SYNC_DRIFT`, ...) and the detail "database upgraded to ..., but the Application did not sync", and the later batches do not run.

The `tpg-instances` ApplicationSet ignores `Postgres spec.postgresVersion` (`RespectIgnoreDifferences=true`), so the operator's admission webhook (`postgresVersion.name cannot be changed ...`) no longer rejects the sync.

```bash
# 1. Operator: dry run on all clusters
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=all -p pushMode=direct -p dryRun=true --watch

# 2. Operator: canary cluster only, through a pull request
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-01 -p pushMode=pr --watch

# 3. Operator: remaining clusters two at a time, without pre-upgrade backups
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=operator -p targetVersion=v4.5.1 -p clusters=aks-tpg-poc-02,aks-tpg-poc-03 \
  -p pushMode=direct -p maxParallel=2 -p preUpgradeBackup=false --watch

# 4. Postgres minor upgrade of every instance on every cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-16.10 -p clusters=all -p instances=all \
  -p pushMode=direct --watch

# 5. Postgres major upgrade of orders-db, with approval between batches
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=postgres-17.6 -p clusters=all -p instances=orders-db \
  -p allowMajor=true -p pushMode=pr -p timeoutSeconds=7200 --watch
argo resume @latest          # approve the next batch after checking the canary

# 6. Postgres minor upgrade of two instances on one cluster
argo submit --from workflowtemplate/tpg-upgrade \
  -p component=postgres -p targetVersion=17.7 -p clusters=aks-tpg-poc-02 \
  -p instances='orders-db,billing-db' -p pushMode=direct --watch
```

---

## 5. tpg-scale-instance

Sets the read replica count of one instance in `clusters/fleet.yaml`, syncs and verifies it.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `cluster` | yes | | One registered cluster |
| `instance` | yes | | Instance declared for that cluster |
| `replicas` | yes | | Read replicas, 0 to `maxReadReplicas` |
| `pushMode` | yes | | `direct` or `pr` |
| `enableHAIfNeeded` | no | `true` | `replicas > 0` on an instance without HA: turn HA on (`true`) or fail (`false`) |
| `dryRun` | no | `false` | Record the change only |
| `timeoutSeconds`, `prTimeoutSeconds` | no | `900`, `3600` | Timeouts |

`replicas=0` removes the read replicas and keeps high availability as declared.

The Application is synced at the pushed commit and waited on until the Postgres resource is `Running`; after a 30-second settle (logged) the workflow checks the pods and StatefulSets with the pod watch.

```bash
# 1. Scale out to 2 read replicas
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-02 -p instance=orders-db -p replicas=2 -p pushMode=direct --watch

# 2. Dry run of scaling to 3
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-01 -p instance=billing-db -p replicas=3 -p pushMode=direct -p dryRun=true --watch

# 3. Scale in to 0 read replicas through a pull request
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-01 -p instance=orders-db -p replicas=0 -p pushMode=pr --watch

# 4. Refuse to turn HA on for a single-node instance
argo submit --from workflowtemplate/tpg-scale-instance \
  -p cluster=aks-tpg-poc-04 -p instance=reporting-db -p replicas=1 \
  -p enableHAIfNeeded=false -p pushMode=direct --watch
```

---

## 6. tpg-delete-apps

Deletes Tanzu Postgres applications per cluster: Postgres instances (`tpg-instances`) and the operator with its CRDs (`tpg-operator`). Deleting the operator removes these CRDs: `postgres`, `postgresbackups`, `postgresbackuplocations`, `postgresbackupschedules`, `postgresrestores`, `postgresversions` and `postgresversionupgrades` (all `.sql.tanzu.vmware.com`).

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `clusters` | yes | | Registered clusters to clean up |
| `apps` | yes | | JSON map: cluster to list of `tpg-instances`, `tpg-instances:<i>[,<i>]`, `tpg-operator`. Every cluster in `clusters` needs an entry |
| `confirm` | yes | | Repeat the `clusters` value |
| `dryRun` | yes | `true` | `true` records the plan; `false` deletes |
| `purgePvcs` | yes | | `true` deletes PVCs and Azure disks; `false` keeps them |
| `purgeNamespace` | yes | | `true` deletes `pg-<instance>` (needs `purgePvcs=true`); `false` keeps it |
| `pushMode` | yes | | `direct` or `pr` |
| `force` | no | `false` | With `tpg-operator`: also delete Postgres instances not listed, and do not wait for running backups or restores |
| `finalBackup` | no | `true` | `true`, `false` or `required` (fail when the instance is not Running) |
| `timeoutSeconds`, `prTimeoutSeconds` | no | `1800`, `3600` | Timeouts |

Order per cluster: instances (final backup, `fleet.yaml` removal, Application removal without cascade, Postgres objects, optional PVC and namespace purge), remaining Tanzu Postgres custom resources, operator (`fleet.yaml`, Application, leftover cluster-scoped objects, namespace `tanzu-postgres-operator`), CRDs. The Azure Blob backup repository is never deleted.

```bash
# 1. Plan (dry run) a full clean-up of two clusters
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=true -p purgePvcs=false -p purgeNamespace=false -p pushMode=direct --watch

# 2. Run it: remove everything, including volumes and namespaces
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p apps='{"aks-tpg-poc-03":["tpg-instances","tpg-operator"],"aks-tpg-poc-04":["tpg-instances","tpg-operator"]}' \
  -p confirm=aks-tpg-poc-03,aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct --watch

# 3. Different applications per cluster: one instance on 01, all instances on 02 (keep volumes)
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p apps='{"aks-tpg-poc-01":["tpg-instances:billing-db"],"aks-tpg-poc-02":["tpg-instances"]}' \
  -p confirm=aks-tpg-poc-01,aks-tpg-poc-02 \
  -p dryRun=false -p purgePvcs=false -p purgeNamespace=false -p pushMode=pr --watch

# 4. Operator only, forcing removal of instances created outside Git, no final backups
argo submit --from workflowtemplate/tpg-delete-apps \
  -p clusters=aks-tpg-poc-04 -p apps='{"aks-tpg-poc-04":["tpg-operator"]}' -p confirm=aks-tpg-poc-04 \
  -p dryRun=false -p purgePvcs=true -p purgeNamespace=true -p pushMode=direct \
  -p force=true -p finalBackup=false --watch
```

With a parameter file (easier for JSON):

```yaml
# delete-lab.yaml
clusters: aks-tpg-poc-03
apps: '{"aks-tpg-poc-03": ["tpg-instances:scratch-db,test-db", "tpg-operator"]}'
confirm: aks-tpg-poc-03
dryRun: "false"
purgePvcs: "true"
purgeNamespace: "true"
pushMode: direct
```

```bash
argo submit --from workflowtemplate/tpg-delete-apps --parameter-file delete-lab.yaml --watch
```

---

## 7. tpg-delete-instance

Guarded delete of one instance (the per-instance step that `tpg-delete-apps` uses).

```bash
# 1. Delete billing-db, keep volumes and namespace
argo submit --from workflowtemplate/tpg-delete-instance \
  -p cluster=aks-tpg-poc-01 -p instance=billing-db -p confirm=billing-db --watch

# 2. Require a final backup, purge volumes and namespace, through a pull request
argo submit --from workflowtemplate/tpg-delete-instance \
  -p cluster=aks-tpg-poc-02 -p instance=orders-db -p confirm=orders-db \
  -p finalBackup=required -p purgePvcs=true -p purgeNamespace=true -p pushMode=pr --watch
```

---

## 8. tpg-helm-addons

Installs or upgrades the Helm releases on target clusters: `cert-manager`, `vault-secrets-operator`, and for the standalone monitoring option `kps` (Prometheus agent) and `tpg-ksm`. The hub releases (`vault`, `vault-secrets-operator`, `kps`) are installed by `tpg-aks-infra/scripts/run.sh --only vault` and `--only addons`.

The steps run `alpine/k8s:1.35.8`, which ships **Helm 4**. Helm 4 removed
the `-a` flag from `helm list` (it lists every release state by default), renamed `--atomic` to
`--rollback-on-failure` and `--force` to `--force-replace`, and takes a registry
domain without a path for `helm registry login`. The shared Helm helpers
(`workflows/scripts/common.sh`, the same block as `tpg-aks-infra/scripts/lib/common.sh`)
select the release states with `--deployed --failed --pending --superseded --uninstalled
--uninstalling` (`HR_LIST_ALL`), which Helm 3 and Helm 4 both accept, so the same script runs on
a workstation with either version. `tpg-fleet/tests/cli-flags` fails the build
when a removed flag comes back.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `clusters` | yes | | Registered clusters or `all` |
| `components` | no | `auto` | `auto` (cert-manager and vso, plus monitoring when `tpg-settings monitoringOption=standalone`), or a list of `cert-manager`, `vso`, `monitoring` |
| `existingAddons` | no | `skip` | A release that exists with another chart version or other values: `skip` (report `SKIPPED_EXISTS`) or `upgrade` |
| `dryRun` | no | `false` | `helm upgrade --install --dry-run=server` |

Every component is classified before anything is installed, and the result is reported per release:

| Status | Meaning |
|---|---|
| `INSTALLED`, `UPGRADED` | The release was created or upgraded by this run |
| `UP_TO_DATE` | Our release, same chart version, same values |
| `SKIPPED_EXISTS` | Our release differs; rerun with `existingAddons=upgrade` to apply |
| `SKIPPED_NEWER` | The installed chart is newer than the pinned version; never downgraded |
| `REUSED_EXISTING` | A cert-manager or Vault Secrets Operator installed by someone else is recent enough and is used as it is |
| `BLOCKED` | Another installation that cannot be reused (a foreign `kps` or Vault, an operation in progress, a controller too old). The cluster is not changed |

While `helm --wait` runs, the pod watch prints the pods of the release's namespace every 5 seconds and stops the install when one cannot start (section 2).

With standalone monitoring, the target's `kps` writes to the hub gateway over https with basic auth: the step first creates the `VaultStaticSecret monitoring/tpg-remote-write` (Vault `tpg/shared/monitoring-remote-write`) and copies the Vault CA to `monitoring/tpg-remote-write-ca`. After the install, the run checks for 5 minutes (`MONITORING_FLOW_TIMEOUT`) that the hub Prometheus receives series labelled `cluster=<cluster>`; if none arrive the cluster ends `FAILED` with `MONITORING_NOT_FLOWING`, and the step log names what to check (the gateway Service, the target's Prometheus logs, the credential). With the Azure option it checks that the `ama-metrics` pods run.

```bash
# 1. Everything the cluster needs, on every cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all --watch

# 2. cert-manager only on a new cluster
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=aks-tpg-poc-04 -p components=cert-manager --watch

# 3. Dry run of the monitoring agent upgrade on two clusters
argo submit --from workflowtemplate/tpg-helm-addons \
  -p clusters=aks-tpg-poc-01,aks-tpg-poc-02 -p components=monitoring -p dryRun=true --watch

# 4. Bring existing releases up to the pinned chart versions and values
argo submit --from workflowtemplate/tpg-helm-addons -p clusters=all -p existingAddons=upgrade --watch
```

---

## 9. tpg-backup

Creates one `PostgresBackup` per selected instance and waits for it.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `backupType` | no | `full` | `full` starts a new chain; `incremental` holds the changes since the previous backup (the daily schedule); `differential` holds the changes since the last full backup |
| `clusters` | no | `all` | Registered clusters or `all` |
| `scheduledOnly` | no | `false` | `true` (used by the CronWorkflows): skip instances with `backup.scheduled: false` |
| `backupTimeoutSeconds` | no | `10800` | Time to wait per backup |

The schedule is one full backup a week and an incremental one on the other days:

| CronWorkflow | Schedule (UTC) | Type |
|---|---|---|
| `tpg-backup-full` | Sunday 00:00 | full |
| `tpg-backup-incr` | Monday to Saturday 00:00 | incremental |
| `tpg-backup-retention` | daily 02:00 | expiry (section 10) |

An incremental backup depends on the full backup and on every incremental before it, so pgBackRest can only expire a whole chain: the full backup and its incrementals go together. That is what makes the retention workflow expire chains rather than single backups. A differential backup depends only on its full backup, which makes single backups expirable but every differential larger than the incremental of the same day; the POC uses incrementals and keeps `differential` available for a manual run.

```bash
# 1. Full backup of every instance on every cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all --watch

# 2. Incremental backup on one cluster
argo submit --from workflowtemplate/tpg-backup -p backupType=incremental -p clusters=aks-tpg-poc-01 --watch

# 3. Same selection as the CronWorkflows (skips backup.scheduled=false instances)
argo submit --from workflowtemplate/tpg-backup -p backupType=full -p clusters=all -p scheduledOnly=true --watch

# Run a CronWorkflow now
argo cron list
argo submit --from cronwf/tpg-backup-full --watch
```

```bash
# What exists, per instance
kubectl --context aks-tpg-poc-01 -n pg-orders-db get postgresbackup \
  -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,PHASE:.status.phase,STARTED:.status.timeStarted
```

---

## 10. tpg-backup-retention

Expires backups that are older than the retention window. It groups every instance's backups into chains (one full backup and the incrementals that follow it), and expires a chain only when its newest backup is older than the window, so no chain is ever left without its full backup. The newest chain is always kept, however old it is, and a backup that is still running, already expired or marked `Failed` is left alone.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `clusters` | no | `all` | Registered clusters or `all` |
| `retentionDays` | no | per instance | Override `backup.retentionDays` (`clusters/_template/cluster.yaml`: 35) for this run |
| `dryRun` | no | `false` | `true`: report the chains that would be expired; change nothing |

```bash
# 1. What the daily run would expire today
argo submit --from workflowtemplate/tpg-backup-retention -p clusters=all -p dryRun=true --watch

# 2. Apply the fleet.yaml retention on every cluster (what the CronWorkflow does)
argo submit --from workflowtemplate/tpg-backup-retention -p clusters=all --watch

# 3. Free space on one cluster: keep two weeks
argo submit --from workflowtemplate/tpg-backup-retention \
  -p clusters=aks-tpg-poc-03 -p retentionDays=14 --watch
```

The per-instance result reads, for example, `EXPIRED 5 backups in 2 chain(s)`, `DRY_RUN would expire 2 of 3 chain(s) older than 35 days` or `NOTHING_TO_EXPIRE`. Expiry is a request to the operator (`spec.expire` on the full backup of the chain): the repository is cleaned by pgBackRest, and the `PostgresBackup` objects disappear when the operator has finished.

---

## 11. tpg-restore

Restores one instance to a chosen recovery point. Four things are chosen independently: the source instance, the recovery point (`mode`), where it is restored to, and whether that target already exists.

| Input | Mandatory | Default | Description |
|---|---|---|---|
| `sourceCluster` | yes | | Registered cluster that runs the instance to restore from |
| `instance` | yes | | Source instance (namespace `pg-<instance>`) |
| `mode` | yes | | `time`, `latest`, `backup`, `lsn` or `xid` |
| `targetTime` | with `mode=time` | | UTC timestamp, for example `2026-09-15T08:30:00Z` |
| `backupName` | with `mode=backup` | | A `PostgresBackup` name in the source namespace |
| `lsn` / `xid` | with `mode=lsn` / `xid` | | Log sequence number, transaction ID |
| `targetCluster` | no | `sourceCluster` | Registered cluster to restore into |
| `targetInstance` | no | `<instance>-restore-<yyyymmddhhmm>` | Instance to restore into; the source instance name means in place |
| `confirm` | when the target instance exists | | Repeat the target instance name: the restore overwrites its data |
| `pushMode` | no | `direct` | Cross-cluster restore to a new instance: how the `clusters/fleet.yaml` entry is published |
| `bestEffort` | no | `false` | Recover as far as the WAL allows instead of failing |
| `restoreTimeoutSeconds`, `prTimeoutSeconds` | no | `7200`, `3600` | Timeouts |

| Target | What the workflow does |
|---|---|
| New instance, same cluster | A one-off clone in its own namespace, not managed by Argo CD. Delete it when the validation is done, or add it to `clusters/fleet.yaml` |
| New instance, another cluster | The instance is added to `clusters/fleet.yaml` with the source settings, its Secrets (from Vault) and its own backup location are rendered from the chart, and the Argo CD Application adopts it after the restore |
| The same instance (in place) | Destructive; needs `confirm=<instance>` |
| Another existing instance | Destructive; needs `confirm=<instance>` |

Before it starts, the workflow reads the source instance's backup location, stanza and Postgres version, and refuses a `targetTime` that is in the future or older than the oldest full backup (`OUTSIDE_RECOVERY_WINDOW`). For a restore into another namespace or cluster it creates a read-only copy of the source backup location there, so `backupSync` lists the source backups for the restore; `mode=backup` restores only inside the source namespace, because a `PostgresBackup` name is namespaced.

```bash
# 1. Point in time into a new instance on the same cluster
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=time -p targetTime=2026-09-15T08:30:00Z --watch

# 2. Latest recoverable point, in place (destructive)
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=latest \
  -p targetInstance=orders-db -p confirm=orders-db --watch

# 3. From one named backup, into a new instance in the same namespace
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=backup -p backupName=orders-db-full-20260914000000 --watch

# 4. Clone to another cluster, managed by Argo CD afterwards
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db -p mode=latest \
  -p targetCluster=aks-tpg-poc-02 -p targetInstance=orders-db-dr -p pushMode=direct --watch

# 5. Up to a transaction ID, best effort
argo submit --from workflowtemplate/tpg-restore \
  -p sourceCluster=aks-tpg-poc-01 -p instance=orders-db \
  -p mode=xid -p xid=987654 -p bestEffort=true --watch
```

Afterwards:

```bash
kubectl --context aks-tpg-poc-01 -n pg-orders-db-restore-202609151030 get postgres,postgresrestore
# The copy of the source backup location is kept on purpose. Delete it only when the
# restore is validated: deleting it also removes the PostgresBackup objects that were
# synced from the source repository into that namespace.
kubectl --context aks-tpg-poc-01 -n pg-orders-db-restore-202609151030 \
  get postgresbackuplocation -l tpg.fleet/restore-source
```

---

## 12. tpg-rotate-credential

The credential itself is changed in Vault; the workflow then verifies that the new value reached everything that uses it. Nothing is edited in a Kubernetes Secret by hand.

```bash
# 1. Write the new value to Vault. In the UI (scripts/run.sh --only access prints the
#    URL and the tpg-admin password), or in a shell in the Vault pod:
kubectl --context aks-tpg-hub -n vault exec -it vault-0 -- sh
#   vault login -method=userpass username=tpg-admin          (prompts for the password)
#   vault kv put tpg/shared/broadcom-registry username=<user> token=<new token>
#   exit

# 2. Verify the propagation
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=broadcom-registry --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=backup-storage --watch
argo submit --from workflowtemplate/tpg-rotate-credential -p secretType=git-push --watch
```

| `secretType` | Vault path | What is checked |
|---|---|---|
| `broadcom-registry` | `tpg/shared/broadcom-registry` | The hub `VaultStaticSecret` and the Argo CD OCI repository connection, then on every cluster: `regsecret` matches Vault, and a test pod pulls an image |
| `backup-storage` | `tpg/shared/backup-storage` | `backup-storage` matches Vault on every cluster, the backup locations are re-read by the operator, and the Blob container answers with HTTP 200 for the new key |
| `git-push` | `tpg/shared/github-push` | The workflow's own Git credential; a `git ls-remote` against the fleet repository |

`tpg/shared/monitoring-remote-write` (standalone monitoring: `username`, `password`) has no `secretType`. After changing it in Vault, run `tpg-aks-infra/scripts/run.sh --only addons`: the hub gateway's htpasswd is rebuilt from Vault and the gateway restarted, and the Vault Secrets Operator updates `monitoring/tpg-remote-write` on every target (within its refresh interval); the step then checks that each target's metrics still reach the hub.

`tpg/shared/github-read` is the Argo CD repository credential: rotate it in Vault and the Vault Secrets Operator updates `repo-tpg-fleet`; `tpg-rotate-credential -p secretType=git-push` covers the credential the workflows push with.

---

## 13. Follow, approve, stop and clean up runs

```bash
argo list                                   # runs with status and duration
argo list --running
argo list -l workflows.argoproj.io/workflow-template=tpg-day0
argo get @latest                            # step tree of the newest run
argo watch @latest
argo logs @latest --follow
argo logs <workflow> -c main | sed -n '/tpg run report/,$p'
kubectl -n argo get configmap tpg-run-<workflow> -o yaml   # raw results per target

argo resume <workflow>                      # approve a suspended step (tpg-upgrade allowMajor=true)
argo suspend <workflow>
argo stop <workflow>                        # run exit handlers (report), then stop
argo terminate <workflow>                   # stop immediately, no exit handler
argo retry <workflow>                       # rerun failed steps
argo resubmit <workflow> --memoized         # new run with the same inputs
argo delete <workflow>                      # also deletes tpg-run-<workflow>
argo delete --older 7d
```

### Archived step logs

Every step's log is archived to Azure Blob when the step ends (container `argo-logs` of the backup storage account). The Argo UI shows the log of a finished step even after its pod has been deleted, for as long as the Workflow exists (7 days). After that, or from a terminal:

```bash
cd tpg-aks-infra
scripts/wf-logs.sh <workflow> --list              # the archived logs of a run
scripts/wf-logs.sh <workflow>                      # print every step log
scripts/wf-logs.sh <workflow> --grep 'RESULT|POD_' # only the matching lines, per step
make wf-logs WF=<workflow>
```

The logs are deleted by the storage lifecycle rule after 90 days (Terraform `argo_logs_retention_days`).

### Reading a failed step

Every step writes its own result: one line `RESULT <key> <status> <reason>
<detail>` in the step log, one key in `tpg-run-<workflow>`, and the output
parameter the report and the Prometheus metric read. A step that fails before it
gets that far records `UNEXPECTED_ERROR` with the script and line number, so a
run never ends with a bare `UNKNOWN`.

```bash
argo logs @latest -c main | grep RESULT
kubectl -n argo get configmap tpg-run-<workflow> -o json | jq '.data | map_values(fromjson)'
```

Reasons written by the sync engine and the pod watch:

| Reason | Meaning | Look at |
|---|---|---|
| `SYNC_REJECTED` | The API server or an admission webhook refused the manifests (invalid or immutable field). Not retried | The detail holds Argo CD's message; fix the spec in Git |
| `SYNC_FAILED` | The sync operation failed for another reason, after the retries | `argocd app get <app> --show-operation` |
| `SYNC_TIMEOUT` | The sync operation did not finish in time | `argocd app get <app>`, the pod table in the step log |
| `SYNC_BUSY` | Another operation on the Application did not end in time | `argocd app terminate-op <app>` if it is stuck |
| `SYNC_DRIFT` | Synced, but resources stay OutOfSync (listed in the detail) | `argocd app diff <app>` |
| `HEALTH_TIMEOUT` | Synced, but not Healthy in time | The Postgres resource `status.currentState`, the pod table |
| `POD_<REASON>` | A pod could not start (`POD_CRASHLOOPBACKOFF`, `POD_IMAGEPULLBACKOFF`, `POD_UNSCHEDULABLE`, ...) | The status, events and logs printed below the pod table |
| `MONITORING_NOT_FLOWING` | A target's metrics did not reach the hub within 5 minutes | `kubectl -n monitoring logs deploy/tpg-remote-write` on the hub, the target's Prometheus logs |

One line in the executor log is **not** an error, however it reads:

```text
level=INFO msg="saving parameter" argo=true src=/tmp/result dst=/var/run/argo/outputs/parameters//tmp/result
```

The Argo executor builds that destination as `/var/run/argo` +
`/outputs/parameters/` + the source path, so an absolute source path always
produces two slashes, and POSIX treats `//` inside a path as one separator. The
failure in such a log is the line above it (`sub-process exited ... exit status
1`): read the step's own `RESULT` line for what went wrong.

---

## 14. argocd CLI: the sync steps behind the workflows

The workflows call the Argo CD API as `workflow-bot`. Use these commands to inspect what a workflow did or to repeat a step by hand. Applications: `tpg-<cluster>-platform`, `tpg-<cluster>-operator`, `tpg-<cluster>-<instance>`, `tpg-hub-workflows`.

```bash
# What exists and its state
argocd app list -l tpg.fleet/cluster=aks-tpg-poc-01
argocd app list -l tpg.fleet/component=operator
argocd app get tpg-aks-tpg-poc-01-orders-db --show-operation
argocd appset get tpg-instances
argocd cluster list

# Hub workflows (templates, scripts, RBAC) after a change in Git
argocd app get tpg-hub-workflows --refresh
argocd app sync tpg-hub-workflows && argocd app wait tpg-hub-workflows --health --timeout 300

# Regenerate Applications right after a fleet.yaml commit (same as the workflows)
kubectl -n argocd annotate applicationset tpg-instances argocd.argoproj.io/application-set-refresh=true --overwrite
kubectl -n argocd annotate applicationset tpg-operator argocd.argoproj.io/application-set-refresh=true --overwrite

# The sync at a given commit, as the workflows do it (the revision of the fleet push)
argocd app sync tpg-aks-tpg-poc-01-orders-db --revision "$(git -C tpg-fleet rev-parse HEAD)"

# Day 0 sync order for one cluster (platform, operator, instances)
argocd app sync tpg-aks-tpg-poc-01-platform && argocd app wait tpg-aks-tpg-poc-01-platform --health --timeout 1800
argocd app sync tpg-aks-tpg-poc-01-operator && argocd app wait tpg-aks-tpg-poc-01-operator --health --timeout 1800
argocd app sync -l tpg.fleet/cluster=aks-tpg-poc-01,tpg.fleet/component=instance
argocd app wait -l tpg.fleet/cluster=aks-tpg-poc-01,tpg.fleet/component=instance --health --timeout 1800

# Operator upgrade check: the rendered chart version after the fleet.yaml commit
argocd app get tpg-aks-tpg-poc-01-operator -o json | jq -r '.spec.source.targetRevision'
argocd app diff tpg-aks-tpg-poc-01-operator

# Scale check: the Postgres spec Argo CD will apply
argocd app manifests tpg-aks-tpg-poc-02-orders-db --source git | yq 'select(.kind == "Postgres") | .spec.highAvailability'
argocd app sync tpg-aks-tpg-poc-02-orders-db --resource sql.tanzu.vmware.com:Postgres:orders-db

# The operator's CRDs and Deployment, which the workflows check directly before hard-refreshing
kubectl --context aks-tpg-poc-01 get crd postgres.sql.tanzu.vmware.com -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
kubectl --context aks-tpg-poc-01 -n tanzu-postgres-operator get deploy

# Troubleshooting a failed sync
argocd app get tpg-aks-tpg-poc-01-orders-db --hard-refresh
argocd app history tpg-aks-tpg-poc-01-orders-db
argocd app terminate-op tpg-aks-tpg-poc-01-orders-db
argocd repo list
```

Do not run `argocd app delete` with cascade on instance Applications: the delete workflows remove them without cascading and delete database objects in order.
