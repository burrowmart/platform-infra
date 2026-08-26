#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Package platform-infra/helm/base-service into every service's helm/charts/.
#
# Why this exists: helm never resolves a chart dependency at install time. It
# uses whatever is already sitting in charts/. Editing base-service therefore
# changes nothing for any service until the packaged copy is refreshed.
#
# charts/ is gitignored — it is a build artifact, not source. CI does not use
# this script: there each service repo is checked out alone, with no sibling
# platform-infra to package from, so CI runs `helm dependency update` and
# pulls the published chart from ghcr.io instead.
#
# Run this after ANY edit to helm/base-service, and before:
#   - helm template / helm install of any service, locally
#   - the acceptance harness (its criterion-5 check renders every chart)
#
#   ./platform-infra/scripts/vendor-base-chart.sh
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
BASE_CHART="$ROOT/platform-infra/helm/base-service"

VERSION="$(awk '/^version:/ {print $2}' "$BASE_CHART/Chart.yaml")"
echo "packaging base-service $VERSION"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
helm package "$BASE_CHART" -d "$TMP" >/dev/null

for dir in "$ROOT"/*/helm; do
  [ -f "$dir/Chart.yaml" ] || continue
  grep -q 'name: base-service' "$dir/Chart.yaml" || continue

  svc="$(basename "$(dirname "$dir")")"
  mkdir -p "$dir/charts"
  # Clear stale copies first: a version bump would otherwise leave the old
  # tarball behind, and helm loads every chart it finds in charts/.
  rm -f "$dir/charts"/base-service-*.tgz
  cp "$TMP/base-service-$VERSION.tgz" "$dir/charts/"
  echo "  $svc"
done

echo "done"
