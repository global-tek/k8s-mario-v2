# Kubernetes App Deployment Diagnostic Report (Post-Summary Segment)

**Date:** 2026-03-25  
**Environment:** `production` namespace  
**Cluster Context:** single-node Linux host (`ip-172-31-2-94`)  
**Application:** `mario-production` (Argo CD managed)

---

## 1) Executive Summary

This report documents the troubleshooting and remediation performed after the earlier summary checkpoint.

### Final Outcome
- Application deployment issue was resolved.
- Argo CD application reached **Synced + Healthy**.
- `mario-deployment` reached **1/1 available**.
- Service endpoint became available on port **80**.
- Istio installation (default profile) failed due to cluster resource limits (primarily memory).

---

## 2) Scope of This Report

This report covers:
1. Port exposure validation for app traffic.
2. Deployment health verification and crash diagnosis.
3. Security-context remediation for NGINX runtime.
4. GitOps synchronization outcomes.
5. Istio install attempt and failure analysis.
6. Current production overlay configuration snapshot.

---

## 3) Detailed Timeline and Findings

## Step 1 — Validate whether app port 80 is open

### Objective
Confirm if the container/service network path is correctly configured for HTTP traffic.

### Findings
- `mario-service` is configured to expose:
  - `port: 80`
  - `targetPort: 80`
- `mario-deployment` container exposes:
  - `containerPort: 80`

### Result
- Port wiring was correct.
- Application still unreachable due to pod readiness/runtime failure, not service port misconfiguration.

---

## Step 2 — Check deployment runtime health

### Objective
Verify pod/deployment readiness status.

### Findings
- Deployment showed unavailable replicas (`0 available`).
- Pods entered `CrashLoopBackOff`.

### Runtime Error Signature
NGINX startup failed with permission-related errors on cache/temp directories (e.g., `/var/cache/nginx/...` with `Operation not permitted`).

### Result
- Root cause shifted from networking suspicion to container runtime permissions/security context.

---

## Step 3 — Apply security-context fix in production overlay

### Objective
Allow NGINX to initialize successfully under Kubernetes constraints.

### Action Taken
Production deployment patch was updated to use a runtime-compatible security context so NGINX can write required paths and start successfully.

### GitOps Flow
- Fix committed and pushed to `main`.
- Argo CD sync executed for `mario-production`.

### Verification Results
- Argo CD status: **Synced / Healthy**.
- Deployment status: **1/1 available**.
- Service endpoint populated on port 80.

### Conclusion
- Primary application outage condition resolved.

---

## Step 4 — Attempt Istio installation

### Objective
Install Istio and enable sidecar injection for production traffic management.

### Commands Run
- `istioctl install --set profile=default -y`
- `kubectl label namespace production istio-injection=enabled`
- `kubectl get pods -n istio-system`

### Observed Results
- `production` namespace labeling succeeded.
- Istio install timed out:
  - `istiod`: `Pending`
  - `istio-ingressgateway`: `ContainerCreating`
  - installer returned `context deadline exceeded`

### Diagnosis
- Cluster has insufficient resources (notably memory) for default Istio control-plane + ingress components.
- Ingress startup dependency chain was blocked while core Istio components were not ready.

### Conclusion
- Istio failure is infrastructure-capacity related, not app manifest corruption.

---

## 4) Current Production Overlay Snapshot

File: `/home/ubuntu/k8s-mario/gitops/overlays/production/kustomization.yaml`

Key values currently present:

- Base resources:
  - `../../base`
  - `canary.yaml`
- Patch strategy:
  - `patchesStrategicMerge: deployment-patch.yaml`
- Image tag:
  - `mario-game:v1.2.0`
- Replica override:
  - `mario-deployment: 1`
- Config map merge:
  - `ENVIRONMENT=production`

Excerpt:
```yaml
replicas:
  - name: mario-deployment
    count: 1
```

---

## 5) Root Cause Summary

### Resolved App Deployment Incident
- **Primary root cause:** container runtime permissions incompatible with NGINX startup requirements.
- **Evidence:** CrashLoopBackOff + NGINX permission errors.
- **Fix:** production security context patch applied and synced through GitOps.

### Unresolved Platform Add-On Incident (Istio)
- **Primary root cause:** insufficient cluster capacity for default Istio profile.
- **Evidence:** `istiod` Pending, ingress `ContainerCreating`, install timeout.
- **Status:** pending infrastructure sizing or reduced Istio profile strategy.

---

## 6) Operational Risks and Recommendations

### Risks
1. Single-node resource ceiling may block additional platform components.
2. Future rollout instability possible if CPU/memory requests are not tuned.
3. Security-context changes that run as root should be reviewed against policy baselines.

### Recommendations
1. **Capacity:** increase node memory/CPU or add worker node before full Istio rollout.
2. **Istio profile:** use a lighter profile for constrained environments.
3. **Policy hardening:** after stabilization, refactor container/image to run non-root safely.
4. **GitOps hygiene:** keep all production fixes committed and synced before runtime testing.

---

## 7) Verification Checklist (Post-Fix)

- [x] Service exposes port 80 correctly.
- [x] Deployment has available replicas.
- [x] Pod no longer CrashLooping from NGINX permission failure.
- [x] Argo CD app is Synced and Healthy.
- [ ] Istio default profile installation successful (currently blocked by resources).

---

## 8) Next Actions

1. Decide Istio path:
   - scale cluster capacity, or
   - reinstall using minimal profile.
2. If security policy requires non-root:
   - adjust image filesystem permissions and NGINX paths,
   - reintroduce stricter `securityContext`.
3. Add baseline monitoring/alerts for:
   - pod restarts,
   - deployment unavailable replicas,
   - node memory pressure.

---

**End of report**