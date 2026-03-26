# Troubleshooting Transcript: Argo CD, EKS, Flagger, Istio, and Prometheus

## Scope
This document captures the troubleshooting journey from the chat session, including symptoms, root causes, fixes applied, and validated outcomes.

## Environment Summary
- Platform: AWS EKS
- Access pattern used during troubleshooting: EC2 bastion host running kubectl
- Main components involved:
  - Argo CD
  - Terraform-managed EKS resources
  - Istio
  - Flagger
  - kube-prometheus-stack (Prometheus + Grafana)

---

## 1) Argo CD Install: CRD Error During Apply

### Symptom
During Argo CD install:
- Most resources were created successfully.
- One error appeared:
  - `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long: may not be more than 262144 bytes`

### Root Cause
`kubectl apply` (client-side apply) attempted to store a large last-applied annotation on the CRD, exceeding Kubernetes annotation size limits.

### Fix Guidance
Use one of the following install methods to avoid this annotation-size failure:
- `kubectl apply --server-side ...`
- or `kubectl create ...` for first-time creation

### Validation
- Argo CD core pods were running.
- Missing CRD could be validated with:
  - `kubectl get crd applicationsets.argoproj.io`

---

## 2) Argo CD Service Reachability: "Unreachable"

### Symptom
- Argo CD server pod and service were healthy.
- Service endpoints existed.
- Access from browser/public IP still failed.
- `ss -ltnp | grep :8080` sometimes showed no listener.

### Root Cause
Two related issues were observed:
1. Port-forward process was not consistently running.
2. When running, it was bound to `127.0.0.1` only, so it was reachable from EC2 localhost but not from outside the host.

### Fix Guidance
- For local host testing on EC2:
  - `kubectl -n argocd port-forward svc/argocd-server 8080:443`
- For external access via EC2 public IP (temporary only):
  - `kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443`
  - Open EC2 Security Group inbound TCP 8080 from trusted source CIDR.

### Validation
- Local check succeeded:
  - `curl -vk https://127.0.0.1:8080`
  - Returned HTTP 200 and Argo CD HTML payload.

### Recommendation
Do not treat node public IP + port-forward as production ingress.
Use ALB Ingress + ACM TLS for durable external access.

---

## 3) Terraform Rename Side Effect: Resource Recreation Conflict

### Symptom
After replacing placeholder Terraform resource labels (`example`, `example1`) with descriptive names:
- Terraform destroyed resources under old addresses.
- Then creation of IAM roles failed with:
  - `EntityAlreadyExists: Role with name ... already exists`

### Root Cause
Terraform state addresses changed (resource label rename), but state mapping was not moved/imported first.
Terraform treated renamed resources as new objects.

### Fix Guidance
Recover state-object mapping by importing existing IAM objects into new addresses:
- import cluster role
- import node role
- import policy attachments

Then run `terraform plan` and `terraform apply`.

### Prevention
For future renames, use one of:
- `moved` blocks in Terraform
- `terraform state mv`

---

## 4) Flagger CRD Install Conflict

### Symptom
Flagger Helm install failed with CRD conflict:
- `Apply failed with 1 conflict ... conflict with "kubectl-client-side-apply" ... .spec.versions`

### Root Cause
CRDs were pre-created via kubectl, then Helm attempted to install/apply CRDs too, causing field-manager ownership conflict.

### Fix Guidance
Use one CRD owner strategy only.
Recommended path used:
- Keep CRDs managed separately.
- Install/upgrade Helm release with `--skip-crds`.

### Notes
Warnings like `unrecognized format "url"` during CRD apply were non-fatal in this context.

---

## 5) Flagger Canary Stuck in Initializing

### Symptom
Canary status showed:
- Phase: `Initializing`
- Event: `mario-deployment-primary ... not ready`
- Event: `0 of 1 updated replicas are available`

### Root Cause
Not a Flagger logic issue. Workload readiness failed because pods were in `CrashLoopBackOff`.

### Evidence
- Production pods showed `1/2 CrashLoopBackOff` (app + istio-proxy sidecar present).
- App logs from `mario-container`:
  - `nginx: [emerg] mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)`

### Diagnosis
NGINX tried to write to a path not writable under enforced non-root/security constraints.

### Fix Guidance
Apply non-root-compatible runtime config, such as:
- writable `emptyDir` mounts for NGINX cache/run paths
- compatible securityContext and filesystem permissions
- or update NGINX config to use writable locations (for example under `/tmp`)

### Outcome
Once primary deployment becomes healthy and available, Flagger can proceed with analysis/promotion.

---

## 6) Prometheus Instance Name for Grafana Variable

### Symptom
Need the correct Prometheus endpoint/instance value.

### Discovery
From services in namespace `monitoring`, the primary Prometheus service was:
- `prometheus-kube-prometheus-prometheus` (port 9090)

### Correct Value
Use this in-cluster URL for Grafana variable/data source expectations that require URL:
- `http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090`

If variable expects only name/identifier, use:
- `prometheus-kube-prometheus-prometheus`

### Additional Clarification
- `prometheus-grafana` is Grafana service, not Prometheus.
- `prometheus-operated` is a headless service and usually not the first choice for standard Grafana datasource URL.

---

## 7) serviceMonitorSelector: How To Find It

### Question
How to identify Prometheus `serviceMonitorSelector`.

### Method
Inspect Prometheus CR spec in the monitoring namespace and read:
- `.spec.serviceMonitorSelector`

### Why It Matters
Prometheus only discovers ServiceMonitors whose labels match this selector. A common mismatch is missing `release` label on ServiceMonitor objects.

---

## Key Lessons Learned
1. Client-side apply on large CRDs can fail due to annotation size limits.
2. Port-forward reachability depends on both process lifetime and bind address.
3. Terraform resource label rename requires state migration/import.
4. Define one owner for CRDs (kubectl or Helm), not both.
5. Flagger readiness issues often reflect app health problems, not Flagger itself.
6. In Istio-injected namespaces, always verify both app and sidecar container health.
7. Prometheus discovery is selector-driven; label alignment is mandatory.

---

## Recommended Stable End State
1. Argo CD external access via ALB Ingress + ACM certificate.
2. CRD installation standardized to server-side apply or dedicated CRD management workflow.
3. Terraform renames guarded with `moved` blocks or `state mv`.
4. App deployment hardened for non-root runtime (write paths and probes verified).
5. Prometheus ServiceMonitor labels aligned with Prometheus `serviceMonitorSelector`.

---

## Quick Command Reference (Used Frequently)

```bash
# Argo CD server-side install (avoids large annotation issue)
kubectl apply --server-side -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Verify missing CRD
kubectl get crd applicationsets.argoproj.io

# Port-forward local only
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Port-forward externally reachable on EC2 (temporary)
kubectl -n argocd port-forward --address 0.0.0.0 svc/argocd-server 8080:443

# Prometheus endpoint verification via forward
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090:9090
curl -s http://127.0.0.1:9090/api/v1/status/buildinfo

# Check canary status/events
kubectl -n production describe canary mario-canary

# Check crashing pod logs
kubectl -n production logs deployment/mario-deployment-primary -c mario-container
```

---

## Final Summary
The main recurring pattern across incidents was healthy control-plane objects with failing data-plane/runtime details: access path binding, state ownership conflicts, and container filesystem/runtime assumptions. Once each ownership and runtime boundary was corrected, behavior aligned with expectations.
