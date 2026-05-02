# Runbook: OOMKilled

## Symptom
Container terminated with reason `OOMKilled` (exit code 137). Kubernetes killed the container because it exceeded its memory limit.

## Common Root Causes
1. Memory leak in application
2. Memory limit set too low for the workload
3. Sudden traffic spike causing increased memory usage
4. JVM heap not configured correctly (Java apps)

## Diagnostic Steps
1. `kubectl describe pod <pod-name>` — confirm OOMKilled in Last State
2. Check memory usage trends in CloudWatch Container Insights
3. Review application logs before the kill event
4. Check if memory limit is appropriate: `kubectl get pod <pod-name> -o jsonpath='{.spec.containers[*].resources}'`

## Remediation

### Immediate fix — increase memory limit:
```bash
kubectl patch deployment <deployment-name> -n <namespace> \
  --patch '{"spec":{"template":{"spec":{"containers":[{
    "name":"<container>",
    "resources":{"limits":{"memory":"1Gi"},"requests":{"memory":"256Mi"}}
  }]}}}}'
```

### For Java apps — set heap size:
Add env var: `JAVA_OPTS=-Xmx512m -Xms128m`

### If traffic spike — scale horizontally:
```bash
kubectl scale deployment <name> --replicas=3 -n <namespace>
```

## Prevention
- Set HPA (Horizontal Pod Autoscaler) to scale before OOM occurs
- Set VPA (Vertical Pod Autoscaler) recommendations
- Add memory usage alerts at 80% threshold
