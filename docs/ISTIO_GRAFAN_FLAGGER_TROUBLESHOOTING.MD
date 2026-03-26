🚀 Troubleshooting Istio & Flagger Observability: A Journey to Metrics
📋 Summary
This document outlines the troubleshooting journey to establish full observability for an Istio-enabled Canary deployment managed by Flagger.

The Goal: Visualize real-time request volume and success rates for a "Mario" application across Primary and Canary deployments in Grafana.
The Tech Stack: Kubernetes, Istio (1.29), Flagger, Prometheus Operator (kube-prometheus-stack), Grafana.
The Ultimate Success: After navigating misconfigured data sources, missing ServiceMonitors, Istio telemetry quirks, and broken default dashboards, we successfully mapped Envoy sidecar metrics to a custom Grafana dashboard, achieving 100% visibility into traffic shifting.

🛑 The Initial Problem
Symptom: The Prometheus service was reachable via curl and port-forwarding, but the Grafana "Flagger Canary Status" dashboard was completely blank ("No Data").

Baseline Checks: Prometheus API (/api/v1/status/buildinfo) returned successful responses, confirming the core monitoring stack was alive.

🗺️ The Troubleshooting Journey (Trial & Error)
Phase 1: The Grafana Data Source Disconnect
Hypothesis: Grafana wasn't talking to Prometheus correctly.

Trial: Checked the dashboard's "Instance name filter" variable.

Error: The filter was hardcoded with the literal URL of the Prometheus service (http://prometheus-kube-...:9090). Grafana expects the internal Data Source Name (e.g., Prometheus), not a URL.

Resolution: Cleared the URL from the regex filter, allowing Grafana to auto-discover the correct Data Source. The Prometheus API connection test immediately passed.

Phase 2: The "Blind" Prometheus (Istio Scraping)
Hypothesis: Grafana is connected, but Prometheus doesn't have any Istio metrics.

Trial: Queried count(istio_requests_total) in Grafana's Explore view. Result: "No Data".

Error: The Prometheus Operator does not automatically scrape Istio out-of-the-box. It requires specific PodMonitors and ServiceMonitors to find the Envoy sidecars.

Resolution: Applied Istio's official prometheus-operator.yaml definitions and verified via localhost:9090/targets that envoy-stats-monitor transitioned to an UP state.

Phase 3: The "No Traffic, No Metrics" Trap
Hypothesis: Prometheus is configured to scrape, but the dashboard is still empty.

Trial: Ran a raw query for istio_requests_total. Still no data.

Error: Istio's Envoy proxies do not generate request metrics until actual traffic passes through them.

Resolution: Spun up a continuous curl loop against the Mario service's LoadBalancer.

Bash
while true; do curl -s -o /dev/null -w "Status: %{http_code}\n" $URL; sleep 0.1; done
Result: Data finally appeared in the Prometheus raw queries!

Phase 4: Metric Labeling & Flagger Naming Quirks
Hypothesis: Data exists, but the dashboard panels and variables are empty.

Trial: Investigated the metric labels directly on the pod using kubectl exec ... curl .../stats/prometheus.

Error: The standard dashboard looked for destination_service_name="mario-service". However, Flagger's architecture routes stable traffic to a generated service named mario-service-primary. Strict string matching in Grafana caused all data to be filtered out.

Resolution: Updated PromQL queries to use Regex matching (=~"mario-service.*") to capture both primary and canary traffic.

Phase 5: The kube-state-metrics Variable Hurdle
Hypothesis: Dashboard dropdowns (Namespace, Workload) are broken.

Trial: Checked Dashboard Settings > Variables.

Error: The variables relied on kube_deployment_status_replicas_available (from kube-state-metrics), which had mismatched labels or were failing to cascade properly from generic AWS/Cluster variables.

Resolution: Rewrote the variable PromQL definitions to source directly from the newly verified metrics, forcing the dropdowns to populate dynamically.

Phase 6: The 404 Application Metrics Trap
Hypothesis: We need a custom ServiceMonitor for the Mario app itself to fix remaining missing data.

Trial: Created a mario-metrics ServiceMonitor pointing to port 80.

Error: Prometheus targets showed a 404 Not Found error. The Mario application code was not instrumented with a /metrics endpoint.

Resolution: Deleted the custom ServiceMonitor. Realized that for Istio/Flagger RED metrics (Rate, Errors, Duration), we do not need application-level metrics. The Envoy sidecar proxy metrics are the single source of truth.

🏆 The Ultimate Solution
Instead of battling a generic, bloated community dashboard that relied on brittle variable chains, we built a custom JSON Grafana Dashboard.

Why this worked:

It stripped away unnecessary dependency variables.

It hardcoded the PromQL queries to target the exact Istio metrics (istio_requests_total).

It accounted for Flagger's naming conventions by explicitly tracking destination_workload="mario-deployment-primary" vs. destination_workload="mario-deployment".

Result: The dashboard immediately lit up with a continuous green line showing 8-9 requests per second and a 100% success rate for the Primary deployment.

🧠 Key Learnings & Gotchas
Data Source Names != URLs: Grafana variables filtering for data sources need the internal Grafana name, not the service URL.

Istio is Lazy (in a good way): istio_requests_total will not exist in Prometheus until a request actually happens. Always generate background load when troubleshooting dashboards.

Flagger Modifies Names: Flagger creates -primary and -canary resources. Generic Istio dashboards will break unless PromQL queries use regex (=~) to capture these suffixes.

Sidecar Metrics > App Metrics: When using an Istio mesh, rely on the Envoy proxy telemetry (/stats/prometheus) for traffic analysis rather than trying to scrape the raw application pods, especially if the app lacks native Prometheus instrumentation.