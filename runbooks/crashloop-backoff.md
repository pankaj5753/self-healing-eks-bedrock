# Runbook: CrashLoopBackOff

## Symptom
Pod status shows `CrashLoopBackOff`. The container starts, crashes, and Kubernetes keeps restarting it with exponential backoff.

## Common Root Causes
1. **Application crash on startup** — missing config, bad env vars, failed DB connection
2. **OOMKilled immediately** — memory limit too low for startup
3. **Liveness probe failure** — probe fires before app is ready
4. **Bad Docker image** — missing entrypoint, corrupted image layer
5. **Secret/ConfigMap missing** — volume mount fails silently

## Diagnostic Steps
1. `kubectl describe pod <pod-name> -n <namespace>` — check Events section
2. `kubectl logs <pod-name> -n <namespace> --previous` — get crash logs
3. Check `Exit Code`: 137=OOMKilled, 1=App error, 139=Segfault

## Remediation

### If OOMKilled (exit code 137):
- Increase memory limit: `kubectl patch deployment <name> --patch '{"spec":{"template":{"spec":{"containers":[{"name":"<name>","resources":{"limits":{"memory":"512Mi"}}}]}}}}'`

### If App error (exit code 1):
- Check env vars and secrets are mounted correctly
- Restart pod: `kubectl delete pod <pod-name> -n <namespace>`

### If Liveness probe:
- Temporarily disable probe, redeploy, investigate startup time

## Escalation
If pod continues crashing after 3 restart attempts with resource increase, escalate to on-call engineer.
