# Full Chat Deployment Diagnosis Summary (2026-03-24)

This document summarizes the full troubleshooting flow from this chat, including commands run, what each command proved, and the resulting fixes.

## Scope

- Environment: Kubernetes + Argo CD + GitOps overlays in `k8s-mario`
- Primary namespaces: `argocd`, `production`
- Main symptoms investigated:
  - Argo CD UI/server appeared unreachable
  - Argo app `mario-production` had `Sync Status: Unknown` / `ComparisonError`
  - Production app pods were in `CrashLoopBackOff`
  - Istio install failed due cluster resource constraints

---

## Phase 1: Argo CD server reachability diagnosis

### 1. Checked whether port-forward process existed

Command:
```bash
ps -ef | grep 'kubectl port-forward svc/argocd-server' | grep -v grep
```
Result:
- Active process found:
  - `kubectl port-forward svc/argocd-server 8080:443 -n argocd --address 0.0.0.0`

Conclusion:
- A local tunnel process was running.

### 2. Checked port-forward log output

Command:
```bash
tail -n 80 argocd_pf.log
```
Result:
- Included:
  - `Forwarding from 0.0.0.0:8080 -> 8080`

Conclusion:
- Tunnel was forwarding local 8080 to service port 443, which currently mapped to backend 8080.

### 3. Checked service and endpoints health

Command:
```bash
kubectl -n argocd get svc argocd-server -o wide
kubectl -n argocd get endpoints argocd-server -o wide
```
Result:
- Service existed (`ClusterIP`) with ports `80`, `443`
- Endpoints present (backend reachable)

Conclusion:
- Argo server backends were alive.

### 4. Verified local listener and protocol behavior

Commands:
```bash
ss -ltnp | grep ':8080'
curl -skI https://127.0.0.1:8080
curl -sI http://127.0.0.1:8080
```
Results:
- Port `8080` listening by `kubectl`
- HTTPS returned `HTTP/1.1 200 OK`
- HTTP returned `307 Temporary Redirect` to HTTPS

Conclusion:
- Argo server was reachable; primary usage requirement was HTTPS.
- Potential user-facing issue was access method/network path, not server outage.

---

## Phase 2: "Cluster not allowing HTTPS traffic" investigation

### 1. Reviewed network policies

Commands:
```bash
kubectl get networkpolicies -A
kubectl get networkpolicies -n argocd -o yaml
```
Result:
- Multiple Argo namespace policies present.
- `argocd-server-network-policy` had:
  - `ingress: - {}`

Conclusion:
- This effectively allows ingress to selected pods; no HTTPS-deny policy found.

### 2. Checked service/pod port mapping

Commands:
```bash
kubectl -n argocd describe svc argocd-server
kubectl -n argocd get pods -l app.kubernetes.io/name=argocd-server -o jsonpath='{.items[0].spec.containers[].ports}'
```
Results:
- Service had:
  - `80 -> 8080`
  - `443 -> 8080`
- Pod exposed `8080` and `8083`

Interpretation at this stage:
- A suspected protocol/target port mismatch was considered.

### 3. Applied interim patch (later reverted)

Command:
```bash
kubectl -n argocd patch svc argocd-server --type='json' -p='[{"op": "replace", "path": "/spec/ports/1/targetPort", "value": 8443}]'
```
Result:
- Service patched, but this introduced a backend port that was not listening.

---

## Phase 3: Definitive Argo CD port-forward failure root cause

### Symptom observed

User saw:
- `Forwarding from 0.0.0.0:8080 -> 8443`
- `failed to connect to localhost:8443 ... connection refused`

### 1. Confirmed incorrect service targetPort

Command:
```bash
kubectl -n argocd get svc argocd-server -o yaml
```
Result:
- `https` was mapped to `targetPort: 8443`

Root cause:
- `argocd-server` pod in this install was not listening on 8443.

### 2. Fixed service mapping

Command:
```bash
kubectl -n argocd patch svc argocd-server --type='json' -p='[{"op":"replace","path":"/spec/ports/1/targetPort","value":8080}]'
```
Result:
- Mapping became:
  - `http:80->8080`
  - `https:443->8080`

### 3. Verified end-to-end

Command:
```bash
kubectl -n argocd port-forward svc/argocd-server 18080:443 --address 127.0.0.1 >/tmp/argocd-pf-check.log 2>&1 &
curl -skI https://127.0.0.1:18080 | head -n 5
```
Result:
- `HTTP/1.1 200 OK`

Conclusion:
- Argo service reachability issue was resolved by restoring `443 -> 8080`.

---

## Phase 4: Argo app sync/comparison failure (`mario-production`)

### Symptom observed

`argocd app get mario-production --refresh` showed:
- `Sync Status: Unknown`
- `ComparisonError`
- `kustomize build ... failed`
- Missing base path error: `.../gitops/base: no such file or directory`
- Deprecation warnings (`bases`, `patchesStrategicMerge`)

### Diagnosis made during chat

- Argo was rendering from GitHub `main`.
- Local changes/manifests had drift relative to what Argo could fetch.
- Overlay/path consistency and committed state were required for proper rendering.

Outcome:
- Later GitOps commits and sync moved app back to `Synced`.

---

## Phase 5: Production app deployment investigation (port 80 question)

### 1. Verified service and deployment ports

Commands:
```bash
kubectl get svc -n production -o yaml
kubectl get deploy -n production -o yaml
kubectl get endpoints -n production -o wide
```
Results:
- Service `mario-service`:
  - `port: 80`
  - `targetPort: 80`
  - `type: LoadBalancer`
- Deployment container had `containerPort: 80`
- Initially, endpoints were empty at one point in troubleshooting due pod readiness issues.

Conclusion:
- Port 80 was correctly exposed/configured, but availability depended on healthy pods.

---

## Phase 6: CrashLoopBackOff root cause and fix

### 1. Captured pod failures and logs

Commands:
```bash
kubectl get deploy,rs,pods,svc -n production -o wide
kubectl describe deployment -n production mario-deployment
kubectl get events -n production --sort-by=.lastTimestamp | tail -n 30
kubectl logs -n production -l app=mario --tail=80 --all-containers=true --prefix=true
kubectl describe pod -n production <pod-name>
```
Key log result:
- NGINX startup error:
  - `chown("/var/cache/nginx/client_temp", 101) failed (1: Operation not permitted)`

Root cause:
- Security context restrictions conflicted with NGINX initialization behavior.

### 2. Patched production overlay security context

File changed:
- `gitops/overlays/production/deployment-patch.yaml`

Applied behavior:
- Set pod/container to run as root for this image runtime path
- Preserved `allowPrivilegeEscalation: false`
- Removed capability drop override by setting empty drop list in patch
- Kept resource requests/limits tuned for constrained node

### 3. Applied and validated

Commands:
```bash
kubectl apply -k gitops/overlays/production
kubectl rollout status deployment/mario-deployment -n production --timeout=180s
kubectl get pods,deploy,svc -n production -o wide
kubectl get endpoints -n production mario-service -o wide
kubectl run curlcheck --rm -i --restart=Never --image=curlimages/curl:8.6.0 -n production -- curl -sS -o /dev/null -w '%{http_code}\n' http://mario-service.production.svc.cluster.local/
```
Results:
- New healthy pod came up (`1/1 Running`)
- Endpoint present: `<pod-ip>:80`
- In-cluster curl returned `200`

Conclusion:
- Runtime permission issue resolved.

---

## Phase 7: GitOps persistence and Argo reconciliation

### 1. Committed security fix

Command:
```bash
git add gitops/overlays/production/deployment-patch.yaml
git commit -m "fix(production): adjust mario security context for nginx startup"
```
Result:
- Commit created: `fef9aa6`

### 2. Initial push failed via SSH

Command:
```bash
git push origin main
```
Result:
- `Permission denied (publickey)`

### 3. Switched to HTTPS auth via GitHub CLI

Commands:
```bash
gh auth status
gh auth setup-git
git remote set-url origin https://github.com/global-tek/k8s-mario.git
git push origin main
```
Result:
- Push succeeded:
  - `5918e1a..fef9aa6  main -> main`

### 4. Forced sync and confirmed health

Commands:
```bash
argocd app sync mario-production
argocd app wait mario-production --health --sync --timeout 180
kubectl get deploy,rs,pods,endpoints -n production -o wide
```
Results:
- Argo app status:
  - `Synced to main (fef9aa6)`
  - `Health Status: Healthy`
- Deployment healthy (`1/1`)
- Only one active healthy ReplicaSet/pod serving endpoint on port 80

---

## Phase 8: Istio installation failure diagnosis

### Symptom observed

`istioctl install --set profile=default -y` reported timeout/resource readiness failures:
- `Istiod encountered an error ... context deadline exceeded`
- Ingress gateway `ContainerCreating`

### 1. Diagnosed pod and node constraints

Commands:
```bash
kubectl get pods -n istio-system -o wide
kubectl describe pod -n istio-system istiod-cd4667d86-ddlb7
kubectl describe pod -n istio-system istio-ingressgateway-b7dbbb799-hx5t4
kubectl describe node | grep -A 10 "Allocatable\|Allocated resources"
```
Results:
- `istiod`: `Pending`, scheduling failures:
  - `Insufficient memory`
  - `Too many pods`
- `istio-ingressgateway`: `ContainerCreating`, mount failed:
  - missing ConfigMap `istio-ca-root-cert` (blocked by incomplete control-plane startup)
- Node resources showed high utilization and pod-count pressure.

Conclusion:
- Istio default profile could not fit current single-node cluster capacity.

---

## End State Summary

1. Argo CD service reachability issue was diagnosed and corrected (`443 -> 8080`).
2. Production app port exposure confirmed on port `80` (Service and container both configured correctly).
3. Main app failure was not networking; it was NGINX security-context incompatibility causing CrashLoop.
4. Production overlay patch fixed startup permissions and restored healthy serving state.
5. GitOps source was updated and pushed; Argo reconciled to commit `fef9aa6` and app became Healthy.
6. Separate Istio installation attempt failed due cluster capacity limits (memory/pod slots).

---

## Key Files Touched During Fixes

- `gitops/overlays/production/deployment-patch.yaml`
- Runtime service patch in cluster for `argocd/argocd-server` (restored `https targetPort` to `8080`)

---

## Practical Lessons Captured

1. For Argo CD behind service port-forward, verify service `targetPort` matches real container listener before changing TLS assumptions.
2. `Sync Status: Unknown` with `ComparisonError` often indicates render/path/repo state mismatch, not necessarily controller crash.
3. Empty service endpoints nearly always trace to pod readiness/health, even when service ports are correct.
4. NGINX-based images can fail under strict non-root and capability-drop defaults unless startup filesystem permissions are compatible.
5. In GitOps, cluster hotfixes must be committed/pushed or Argo will eventually reconcile away local drift.
6. Istio default profile can exceed small-node budgets; use minimal profiles or increase cluster capacity.
