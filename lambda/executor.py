"""
EKS Action Executor Lambda
Called by Bedrock Agent Action Group to perform kubectl operations
Uses the Kubernetes Python client via boto3 EKS token
"""

import json
import os
import subprocess
import tempfile
import base64
import boto3
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def get_kubeconfig(cluster_name: str, region: str) -> dict:
    """Generate kubeconfig from EKS describe-cluster."""
    eks = boto3.client("eks", region_name=region)
    cluster = eks.describe_cluster(name=cluster_name)["cluster"]
    return {
        "endpoint": cluster["endpoint"],
        "ca_data": cluster["certificateAuthority"]["data"],
        "cluster_name": cluster_name,
        "region": region,
    }


def run_kubectl(args: list, cluster_name: str, region: str) -> dict:
    """Run kubectl using aws-iam-authenticator token."""
    cluster_info = get_kubeconfig(cluster_name, region)

    # Write kubeconfig to temp file
    kubeconfig = {
        "apiVersion": "v1",
        "clusters": [{
            "name": cluster_name,
            "cluster": {
                "server": cluster_info["endpoint"],
                "certificate-authority-data": cluster_info["ca_data"],
            }
        }],
        "contexts": [{
            "name": "default",
            "context": {"cluster": cluster_name, "user": "lambda"}
        }],
        "current-context": "default",
        "users": [{
            "name": "lambda",
            "user": {
                "exec": {
                    "apiVersion": "client.authentication.k8s.io/v1beta1",
                    "command": "aws",
                    "args": ["eks", "get-token", "--cluster-name", cluster_name, "--region", region],
                }
            }
        }]
    }

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        import yaml
        yaml.dump(kubeconfig, f)
        kubeconfig_path = f.name

    try:
        cmd = ["kubectl", "--kubeconfig", kubeconfig_path] + args
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        return {
            "stdout": result.stdout,
            "stderr": result.stderr,
            "returncode": result.returncode,
        }
    except subprocess.TimeoutExpired:
        return {"stdout": "", "stderr": "kubectl command timed out", "returncode": 1}
    finally:
        import os as _os
        _os.unlink(kubeconfig_path)


def lambda_handler(event, context):
    logger.info(f"Action executor called: {json.dumps(event)}")

    cluster_name = os.environ["EKS_CLUSTER_NAME"]
    region = os.environ["AWS_REGION_NAME"]

    # Bedrock Agent passes action details in this structure
    api_path = event.get("apiPath", "")
    request_body = event.get("requestBody", {}).get("content", {}).get("application/json", {}).get("properties", [])

    # Convert properties list to dict
    params = {p["name"]: p["value"] for p in request_body}

    logger.info(f"Action: {api_path}, Params: {params}")

    if api_path == "/get_pod_logs":
        namespace = params.get("namespace", "default")
        pod_name = params["pod_name"]
        tail = params.get("tail_lines", 100)
        result = run_kubectl(["logs", pod_name, "-n", namespace, f"--tail={tail}", "--previous"], cluster_name, region)
        if result["returncode"] != 0:
            result = run_kubectl(["logs", pod_name, "-n", namespace, f"--tail={tail}"], cluster_name, region)

    elif api_path == "/restart_pod":
        namespace = params.get("namespace", "default")
        pod_name = params["pod_name"]
        result = run_kubectl(["delete", "pod", pod_name, "-n", namespace], cluster_name, region)

    elif api_path == "/scale_deployment":
        namespace = params.get("namespace", "default")
        deployment = params["deployment"]
        replicas = params["replicas"]
        result = run_kubectl(
            ["scale", "deployment", deployment, f"--replicas={replicas}", "-n", namespace],
            cluster_name, region
        )

    elif api_path == "/update_resource_limits":
        namespace = params.get("namespace", "default")
        deployment = params["deployment"]
        memory = params.get("memory_limit", "512Mi")
        cpu = params.get("cpu_limit", "500m")
        patch = json.dumps({
            "spec": {
                "template": {
                    "spec": {
                        "containers": [{
                            "name": deployment,
                            "resources": {
                                "limits": {"memory": memory, "cpu": cpu},
                                "requests": {"memory": "128Mi", "cpu": "100m"},
                            }
                        }]
                    }
                }
            }
        })
        result = run_kubectl(
            ["patch", "deployment", deployment, "-n", namespace, "--patch", patch],
            cluster_name, region
        )
    else:
        result = {"stdout": "", "stderr": f"Unknown action: {api_path}", "returncode": 1}

    # Bedrock Agent expects this response format
    response_body = result["stdout"] if result["returncode"] == 0 else f"ERROR: {result['stderr']}"

    return {
        "messageVersion": "1.0",
        "response": {
            "actionGroup": event.get("actionGroup", ""),
            "apiPath": api_path,
            "httpMethod": event.get("httpMethod", "POST"),
            "httpStatusCode": 200 if result["returncode"] == 0 else 500,
            "responseBody": {
                "application/json": {
                    "body": json.dumps({"result": response_body})
                }
            }
        }
    }
