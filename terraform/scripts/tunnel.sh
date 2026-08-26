#!/usr/bin/env bash
# Opens (or reuses) an SSM Session Manager port-forward from localhost:6443 to
# the k3s API server, which is how every kubectl/helm/terraform call reaches
# the cluster. The node's security group has no inbound rules, by design.
set -euo pipefail

cd "$(dirname "$0")/.."

if timeout 2 bash -c "</dev/tcp/127.0.0.1/6443" 2>/dev/null; then
  echo "tunnel already up on 127.0.0.1:6443"
  exit 0
fi

INSTANCE_ID="$(cd cluster && terraform output -raw instance_id)"
REGION="$(cd cluster && terraform output -raw aws_region)"

echo "opening SSM port-forward to ${INSTANCE_ID}..."
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$REGION" \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["6443"],"localPortNumber":["6443"]}' \
  >/dev/null 2>&1 &

for i in $(seq 1 30); do
  if timeout 2 bash -c "</dev/tcp/127.0.0.1/6443" 2>/dev/null; then
    echo "tunnel up on 127.0.0.1:6443 (backgrounded; kill it with: pkill -f StartPortForwardingSession)"
    exit 0
  fi
  sleep 2
done

echo "tunnel never came up. Check that the session-manager-plugin is installed:" >&2
echo "  https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html" >&2
exit 1
