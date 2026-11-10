# Incident Runbook: Robot Shop

**Rule: mitigate first, diagnose second.** Restore service by the fastest safe action. Find the root cause once users are no longer affected.

## 0. Setup (once, at the start of an incident or drill)

Open each tunnel in its own terminal. The loop reconnects if the connection drops.

```bash
while true; do kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80; sleep 2; done
while true; do kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090; sleep 2; done
while true; do kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093; sleep 2; done
while true; do kubectl -n tracing port-forward svc/jaeger 16686:16686; sleep 2; done
```

Open Grafana (<http://localhost:3000>) and the dashboard **Robot Shop: Requests, Errors, Latency**. Start a notes file and record the time you start. You will need these times for the postmortem.

## 1. Triage (first 5 minutes)

Write down the time and the symptom, then answer three questions.

**Which signal is wrong?** On the dashboard, check availability per probe (which path is failing), the 5xx ratio, p95 latency and errors by service.

**What changed recently?**

```bash
helm history robot-shop -n robot-shop
kubectl -n robot-shop get events --sort-by=.lastTimestamp | tail -20
kubectl -n robot-shop rollout history deploy/<name>
```

**Is anything unhealthy?** This prints only pods that are not fully ready:

```bash
kubectl get pods -A --no-headers | awk '{split($3,a,"/"); if ($4!="Completed" && (a[1]!=a[2] || $4!="Running")) print}'
kubectl -n robot-shop get deploy
```

## 2. Mitigate by symptom

| What you see | Likely cause | First action |
|---|---|---|
| `ImagePullBackOff` or `ErrImagePull` | Bad image tag or registry problem | `kubectl -n robot-shop rollout undo deploy/<name>` |
| `CrashLoopBackOff` after a change | Bad image or configuration | `rollout undo`, then read `kubectl -n robot-shop logs <pod> --previous` |
| Deployment at 0 replicas, or pods missing | Scaled down | `kubectl -n robot-shop scale deploy/<name> --replicas=1` |
| Dependents error or time out (5 s probe latency, 504s) | A dependency is down (database, queue, cache) | Restore the dependency, then `kubectl -n robot-shop rollout restart deploy/<dependent>` if it does not reconnect |
| `OOMKilled` or repeated restarts | Memory limit too low, or a leak | Roll back the change, or raise the limit with `kubectl -n robot-shop set resources deploy/<name> --limits=memory=<value>` |
| Pods `Pending` | No capacity, or a volume problem | `kubectl -n robot-shop describe pod <pod>`, `kubectl get nodes` |
| Site unreachable but pods healthy | Ingress or load balancer | `kubectl -n robot-shop describe ingress web`, check target health in the AWS console |

**Dependencies.** Observed in our tests: when MongoDB was down, `catalogue` and `user` failed, the catalogue probe dropped to 0, and `cart` was unaffected. Expected from the application design, and to be verified: `cart` and `user` use Redis, `shipping` and `ratings` use MySQL, `payment` and `dispatch` use RabbitMQ.

## 3. Confirm recovery

- `probe_success` is 1 for all three targets (use the instant value in Prometheus, because the dashboard's 5-minute average lags).
- The 5xx ratio is falling and error log lines have stopped.
- The alert has resolved in Alertmanager (<http://localhost:9093>).
- `kubectl -n robot-shop get pods` shows everything `1/1 Running`.

Record the time of recovery.

## 4. Diagnose (after service is restored)

**Prometheus**

```
increase(kube_pod_container_status_restarts_total{namespace="robot-shop"}[30m]) > 0
kube_pod_container_status_last_terminated_reason{namespace="robot-shop"} == 1
kube_deployment_status_replicas_available{namespace="robot-shop"} < kube_deployment_spec_replicas{namespace="robot-shop"}
```

**Loki (Grafana Explore)**

```
sum by (service) (count_over_time({namespace="robot-shop", level="error"} != "agent host candidates" [15m]))
{namespace="robot-shop", service="<name>", level="error"} != "agent host candidates"
```

**Kubernetes**

```bash
kubectl -n robot-shop describe pod <pod>
kubectl -n robot-shop logs <pod> --previous
```

**Traces.** In Jaeger (<http://localhost:16686>), search the instrumented service for slow or errored traces and compare them with healthy ones.

Work out the trigger (what changed), the root cause (why it caused harm) and why detection or recovery took as long as it did.

## 5. Capture evidence

Take screenshots at each stage: the alert firing, the dashboard at its worst, the mitigation command and its output, and the recovered state. Keep a timeline with three times: detected, mitigated and recovered.

## 6. Afterwards

Fill in `postmortem-template.md` within 5 working days, and calculate the error budget consumed.
