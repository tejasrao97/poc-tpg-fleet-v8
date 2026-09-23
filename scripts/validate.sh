#!/usr/bin/env bash
# Static validation of tpg-fleet. Requires: yamllint, shellcheck, kustomize,
# helm, kubeconform, python3 (PyYAML), jq, yq v4.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
CATALOG='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

echo "== yamllint";   yamllint -s .
echo "== shellcheck"; shellcheck -x -e SC1091 workflows/scripts/*.sh scripts/*.sh tests/*.sh tests/*/*.sh monitoring/grafana/import-azure-grafana.sh

# Flags the pinned CLIs no longer accept (helm list -a under Helm 4, and the
# rest of tests/cli-flags/rules.yaml), plus helm-addons.sh against a Helm 4 CLI.
echo "== tests"; tests/run-all.sh

echo "== kustomize build"
for d in workflows platform/base monitoring/azure/targets monitoring/azure/hub monitoring/standalone/targets monitoring/standalone/hub; do
  kustomize build "$d" > "$OUT/$(tr / _ <<<"$d").yaml"
  echo "ok $d"
done

echo "== fleet.yaml structure"
yq -e '.clusters | type == "!!map"' clusters/fleet.yaml >/dev/null
for c in $(yq -r '.clusters | keys | .[]' clusters/fleet.yaml); do
  C="$c" yq -e '.clusters[strenv(C)].operator.version | type == "!!str"' clusters/fleet.yaml >/dev/null \
    || { echo "clusters.${c}.operator.version is required" >&2; exit 1; }
  for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' clusters/fleet.yaml); do
    C="$c" I="$i" yq -e '.clusters[strenv(C)].instances[strenv(I)].instance.postgresVersion | test("^postgres-[0-9]")' clusters/fleet.yaml >/dev/null \
      || { echo "clusters.${c}.instances.${i}.instance.postgresVersion is required (postgres-<version>)" >&2; exit 1; }
  done
done
echo "ok clusters/fleet.yaml"

# values_for CLUSTER INSTANCE -> the Helm values the tpg-instances ApplicationSet passes
# shellcheck disable=SC2016  # yq variables, not shell
values_for() {
  C="$1" I="$2" yq '.clusters[strenv(C)] as $c | ($c.instances[strenv(I)] // {}) as $i
    | ($c | with_entries(select(.key != "instances" and .key != "operator")))
    * {"cluster": {"name": strenv(C)}, "backup": {"container": "pg-backups-" + strenv(C)}}
    * $i * {"instance": {"name": strenv(I)}}' clusters/fleet.yaml
}

echo "== helm lint / template (every fleet.yaml instance)"
mkdir -p "$OUT/values"
for c in $(yq -r '.clusters | keys | .[]' clusters/fleet.yaml); do
  for i in $(C="$c" yq -r '.clusters[strenv(C)].instances // {} | keys | .[]' clusters/fleet.yaml); do
    values_for "$c" "$i" > "$OUT/values/$c-$i.yaml"
    set -- -f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml -f "$OUT/values/$c-$i.yaml"
    helm lint charts/tpg-instance "$@" >/dev/null
    helm template "$i" charts/tpg-instance "$@" --namespace "pg-$i" > "$OUT/chart_${c}_${i}.yaml"
    # PostgresBackupLocation must not carry the two fields the CRD drops on
    # apply (spec.additionalParameters when empty, spec.storage.azure.forcePathStyle
    # when false). Rendering them makes the Application OutOfSync for good.
    if yq 'select(.kind == "PostgresBackupLocation") | .spec
           | (has("additionalParameters"), (.storage.azure | has("forcePathStyle")))' \
         "$OUT/chart_${c}_${i}.yaml" | grep -qx true; then
      echo "PostgresBackupLocation for ${c}/${i} renders additionalParameters or forcePathStyle;" >&2
      echo "the CRD drops both on apply and the Application never reaches Synced" >&2
      exit 1
    fi
    echo "ok ${c}/${i}"
  done
done

echo "== chart: enableSSL of the backup location"
# Always rendered, false by default (clusters/_template/cluster.yaml and the
# chart), true when a cluster or instance sets backup.enableSSL: true.
base=(-f clusters/_template/cluster.yaml -f clusters/_template/instance.yaml
      --set cluster.name=c1 --set instance.name=i1 --set instance.postgresVersion=postgres-17.6
      --set backup.container=pg-backups-c1)
for want in false true; do
  extra=(); [[ "$want" == "false" ]] || extra=(--set backup.enableSSL=true)
  got="$(helm template i1 charts/tpg-instance "${base[@]}" "${extra[@]}" --namespace pg-i1 \
    | yq 'select(.kind == "PostgresBackupLocation") | .spec.storage.azure.enableSSL')"
  [[ "$got" == "$want" ]] || { echo "PostgresBackupLocation enableSSL renders '${got}', expected ${want}" >&2; exit 1; }
  echo "ok enableSSL ${want}"
done
# The ApplicationSet must leave spec.postgresVersion of a running instance to
# the PostgresVersionUpgrade (tpg-upgrade), and ignore enableSSL false.
yq -e '.spec.template.spec.ignoreDifferences[] | select(.kind == "Postgres") | .jsonPointers[] | select(. == "/spec/postgresVersion")' \
  bootstrap/appsets/tpg-instances.yaml >/dev/null
yq -e '.spec.template.spec.syncPolicy.syncOptions[] | select(. == "RespectIgnoreDifferences=true")' \
  bootstrap/appsets/tpg-instances.yaml >/dev/null
echo "ok tpg-instances ignores Postgres spec.postgresVersion (RespectIgnoreDifferences)"

echo "== kubeconform"
cp bootstrap/*.yaml bootstrap/appsets/*.yaml "$OUT/"
for f in bootstrap/monitoring/*/*.yaml; do cp "$f" "$OUT/$(tr / _ <<<"$f")"; done
kubeconform -strict -summary -ignore-missing-schemas \
  -schema-location default -schema-location "$CATALOG" "$OUT"/*.yaml

echo "== JSON"
for d in tpg-fleet tpg-instance tpg-replication tpg-backup tpg-alerts; do
  jq -e --arg u "$d" '.uid == $u and (.panels | length > 0)' "monitoring/standalone/hub/dashboards/${d}.json" >/dev/null \
    || { echo "dashboard ${d} is missing or empty (run monitoring/grafana/generate.py)" >&2; exit 1; }
  grep -q "dashboards/${d}.json" monitoring/standalone/hub/kustomization.yaml \
    || { echo "dashboard ${d} is not in monitoring/standalone/hub/kustomization.yaml" >&2; exit 1; }
done
for f in monitoring/grafana/alerts/api/*.json; do jq -e '.uid and .data' "$f" >/dev/null; done
echo "ok dashboards and alert payloads"

echo "== generated files are up to date"
python3 monitoring/grafana/generate.py >/dev/null
git diff --quiet -- monitoring || { echo "run monitoring/grafana/generate.py and commit the result" >&2; exit 1; }
echo "All checks passed"
