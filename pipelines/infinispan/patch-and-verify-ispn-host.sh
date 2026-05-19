#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="${NAMESPACE:-infinispan}"
CLUSTER_NAME="${CLUSTER_NAME:-ispn-host}"
EXPECTED_REPLICAS="${EXPECTED_REPLICAS:-3}"
DNS_SUFFIX="${DNS_SUFFIX:-cluster.regiontwo}"

DNS_QUERY="${CLUSTER_NAME}-ping.${NAMESPACE}.svc.${DNS_SUFFIX}"

echo "[INFO] Namespace=${NAMESPACE}"
echo "[INFO] Cluster=${CLUSTER_NAME}"
echo "[INFO] Expected replicas=${EXPECTED_REPLICAS}"
echo "[INFO] DNS query=${DNS_QUERY}"

echo "[INFO] Waiting for StatefulSet ${CLUSTER_NAME}"
kubectl -n "${NAMESPACE}" wait \
  --for=jsonpath='{.metadata.name}' \
  "sts/${CLUSTER_NAME}" \
  --timeout=180s

echo "[INFO] Patch StatefulSet securityContext for PVC write permission"
kubectl -n "${NAMESPACE}" patch statefulset "${CLUSTER_NAME}" --type='merge' -p '{
  "spec": {
    "template": {
      "spec": {
        "securityContext": {
          "fsGroup": 65532,
          "fsGroupChangePolicy": "OnRootMismatch"
        }
      }
    }
  }
}'

echo "[INFO] Wait for StatefulSet rollout"
kubectl -n "${NAMESPACE}" rollout status "sts/${CLUSTER_NAME}" --timeout=300s

echo "[INFO] Check pods"
kubectl -n "${NAMESPACE}" get pods -l "clusterName=${CLUSTER_NAME}" -o wide

READY_COUNT="$(kubectl -n "${NAMESPACE}" get pods -l "clusterName=${CLUSTER_NAME}" \
  --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | wc -l | tr -d ' ')"

if [ "${READY_COUNT}" -lt "${EXPECTED_REPLICAS}" ]; then
  echo "[ERROR] Running pod count ${READY_COUNT} is less than expected ${EXPECTED_REPLICAS}"
  exit 1
fi

echo "[INFO] Check PVC"
kubectl -n "${NAMESPACE}" get pvc

PVC_COUNT="$(kubectl -n "${NAMESPACE}" get pvc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -c "data-volume-${CLUSTER_NAME}" || true)"

if [ "${PVC_COUNT}" -lt "${EXPECTED_REPLICAS}" ]; then
  echo "[ERROR] PVC count ${PVC_COUNT} is less than expected ${EXPECTED_REPLICAS}"
  exit 1
fi

echo "[INFO] Check StatefulSet securityContext"
SECURITY_CONTEXT="$(kubectl -n "${NAMESPACE}" get sts "${CLUSTER_NAME}" \
  -o jsonpath='{.spec.template.spec.securityContext}')"
echo "${SECURITY_CONTEXT}"

echo "${SECURITY_CONTEXT}" | grep -q '"fsGroup":65532' || {
  echo "[ERROR] fsGroup=65532 not found in StatefulSet securityContext"
  exit 1
}

echo "[INFO] Check JVM arguments from ${CLUSTER_NAME}-0"
JVM_ARGS="$(kubectl -n "${NAMESPACE}" logs "${CLUSTER_NAME}-0" | grep "JVM arguments" || true)"
echo "${JVM_ARGS}"

echo "${JVM_ARGS}" | grep -q -- "-Dinfinispan.cluster.stack=kubernetes" || {
  echo "[ERROR] -Dinfinispan.cluster.stack=kubernetes not found"
  exit 1
}

echo "${JVM_ARGS}" | grep -q -- "-Djgroups.dns.query=${DNS_QUERY}" || {
  echo "[ERROR] -Djgroups.dns.query=${DNS_QUERY} not found"
  exit 1
}

echo "[INFO] Wait for Infinispan WellFormed=True"
kubectl -n "${NAMESPACE}" wait \
  --for=condition=WellFormed \
  --timeout=300s \
  "infinispans.infinispan.org/${CLUSTER_NAME}"

echo "[INFO] Print Infinispan conditions"
kubectl -n "${NAMESPACE}" get infinispan "${CLUSTER_NAME}" \
  -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{" / "}{.message}{"\n"}{end}'

echo "[INFO] Check cluster view from ${CLUSTER_NAME}-0"
CLUSTER_VIEW="$(kubectl -n "${NAMESPACE}" logs "${CLUSTER_NAME}-0" | grep "Received new cluster view" | tail -n 5 || true)"
echo "${CLUSTER_VIEW}"

echo "${CLUSTER_VIEW}" | grep -q "(${EXPECTED_REPLICAS})" || {
  echo "[ERROR] Expected cluster view (${EXPECTED_REPLICAS}) not found"
  exit 1
}

echo "[SUCCESS] ${CLUSTER_NAME} is patched and verified successfully"
