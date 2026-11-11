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

Open Grafana (<http://localhost:3000>) and the dashboard **Robot Shop: Requests, Errors, Latency**.

Keep a timeline. Grafana shows your browser's local time, so record your notes in UTC with this helper and state the timezone in the postmortem:

```bash
note() { echo "$(date -u +%H:%M:%SZ) $*" | tee -a incident/drill-notes.txt; }
note "incident start: <symptom>"
```

## 1. Triage (first 5 minutes)

Write down the time and the symptom, then answer three questions.

**Which signal is wrong?** On the dashboard, check availability per probe (which path is failing), the 5xx ratio, p95 latency and errors by service.

The availability probes cover only the front page, catalogue and shipping. If the probes are green but something still looks wrong, look at errors by service (cart, user, ratings and payment are not probed):

```
sum by (service) (count_over_time({namespace="robot-shop", level=~"error|unknown"} [15m]))
```

**What changed recently?** Manual changes (patches, annotations, scaling) do not appear in `helm history`, so check all three:

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

### Rolling back safely

- **`kubectl rollout undo` with no revision flips between the last two revisions.** Running it twice puts the bad change back. Never repeat it.
- Pick the last known good revision and name it:

  ```bash
  kubectl -n robot-shop rollout history deploy/<name>
  kubectl -n robot-shop rollout undo deploy/<name> --to-revision=<last good>
  kubectl -n robot-shop rollout status deploy/<name> --timeout=180s
  ```

- If the bad change is one setting (an annotation, an environment variable, an image tag), undo that change directly.
- For changes made through the chart, use `helm history robot-shop -n robot-shop`, then `helm rollback robot-shop <revision> -n robot-shop`.
- Afterwards, confirm the running version: `kubectl -n robot-shop get deploy <name> -o jsonpath='{.spec.template.spec.containers[0].image}'; echo`

### By symptom

| What you see | Likely cause | First action |
|---|---|---|
| Dashboard empty or "No data", or a tunnel keeps dropping | The monitoring side is broken, not the shop | `kubectl -n monitoring get pods`. The port-forward loops reconnect on their own. Do not diagnose the shop from a dead dashboard. |
| `ImagePullBackOff` or `ErrImagePull` after a change | Bad image tag or registry problem | Roll back as above. Old pods keep serving until the new ones are ready, so check whether users are actually affected. |
| `CrashLoopBackOff` after a change | Bad image, configuration or injected agent | Roll back or remove the change, as above. Services without a readiness probe (such as `cart`) lose their working pod as soon as the new one starts, so act quickly. Read the crash in Loki (section 4). |
| OpenTelemetry-injected pod fails | Agent incompatible with the service | Remove the annotation (`<language>` is `java`, `nodejs` or `python`): `kubectl -n robot-shop patch deployment <name> --type json -p '[{"op":"remove","path":"/spec/template/metadata/annotations/instrumentation.opentelemetry.io~1inject-<language>"}]'` |
| Deployment at 0 replicas, or pods missing | Scaled down | `kubectl -n robot-shop scale deploy/<name> --replicas=1` |
| Dependents error or time out (5 s probe latency, 504s) | A dependency is down (database, queue, cache) | Restore the dependency, then `kubectl -n robot-shop rollout restart deploy/<dependent>` if it does not reconnect. MongoDB and MySQL have no volume, so a restart resets them (Redis keeps its data on a 1 GiB gp3 volume). |
| `OOMKilled` or repeated restarts | Memory limit too low, or a leak | Roll back the change, or raise the limit with `kubectl -n robot-shop set resources deploy/<name> --limits=memory=<value>` |
| Pods `Pending` | No capacity, or a volume problem | `kubectl -n robot-shop describe pod <pod>`, `kubectl get nodes` |
| Site unreachable but pods healthy | Ingress or load balancer | `kubectl -n robot-shop describe ingress web`, check target health in the AWS console |
| The site is down but no alert arrived | The rules or Alertmanager are not loaded, or the failed path is not probed | Check Alerts in Prometheus for `RobotShopAvailabilityFastBurn`. If it is inactive, see Known gaps: the probes do not cover cart, user, ratings or payment. |

### Dependencies

Observed in our tests: when MongoDB was down, `catalogue` and `user` failed, the catalogue probe dropped to 0, and `cart` was unaffected. Observed in the MySQL rehearsal: `ratings` failed its readiness probe (HTTP 500) while MySQL was down or starting. Expected from the application design, and to be verified: `cart` and `user` use Redis, `shipping` and `ratings` use MySQL, `payment` and `dispatch` use RabbitMQ.

## 3. Confirm recovery

- `probe_success` is 1 for all three targets (use the instant value in Prometheus, because the dashboard's 5-minute average lags).
- The 5xx ratio is falling and error log lines have stopped.
- The alert has resolved in Alertmanager (<http://localhost:9093>).
- `kubectl -n robot-shop get pods` shows everything `1/1 Running`, with no new restarts.

Record the time of recovery with `note "RECOVERED: ..."`.

## 4. Diagnose (after service is restored)

**Prometheus**

```
increase(kube_pod_container_status_restarts_total{namespace="robot-shop"}[30m]) > 0
kube_pod_container_status_last_terminated_reason{namespace="robot-shop"} == 1
kube_deployment_status_replicas_available{namespace="robot-shop"} < kube_deployment_spec_replicas{namespace="robot-shop"}
```

**Loki (Grafana Explore).** Stack-trace lines are labelled `unknown`, so search for both levels:

```
sum by (service) (count_over_time({namespace="robot-shop", level=~"error|unknown"} [15m]))
{namespace="robot-shop", service="<name>", level=~"error|unknown"}
```

A crashed pod's logs are gone from the cluster once it is replaced, but Loki keeps them. Use the pod name prefix (the Deployment name and the ReplicaSet hash from `kubectl get events`). The first error is the oldest line, so sort oldest first or scroll to the bottom:

```
{namespace="robot-shop", service="<name>", pod=~"<name>-<replicaset-hash>.*"}
```

**Kubernetes**

```bash
kubectl -n robot-shop describe pod <pod>
kubectl -n robot-shop logs <pod> --previous      # only while that pod still exists
kubectl -n robot-shop get events --sort-by=.lastTimestamp | tail -30
```

**Traces.** In Jaeger (<http://localhost:16686>), search the instrumented service (`shipping`) for slow or errored traces and compare them with healthy ones.

Work out the trigger (what changed), the root cause (why it caused harm) and why detection or recovery took as long as it did.

## 5. Capture evidence

Take screenshots at each stage: the alert firing, the dashboard at its worst, the mitigation command and its output, and the recovered state. Use `note` to record three times: detected, mitigated and recovered.

## 6. Known gaps

- The probes do not cover `cart`, `user`, `ratings` or `payment`, so an outage there will not fire the availability alert.
- Several services (such as `cart`) have no readiness probe, so a crash-looping new pod can replace a working one.
- MongoDB and MySQL have no persistent volume, so restarting either one resets its data. Redis keeps its data on a 1 GiB gp3 volume.

## 7. Afterwards

Fill in `postmortem-template.md` within 5 working days, and calculate the error budget consumed.
