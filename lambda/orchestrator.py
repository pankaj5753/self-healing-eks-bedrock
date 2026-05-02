"""
Bedrock Orchestrator Lambda
Triggered by SNS → CloudWatch Alarm (pod CrashLoopBackOff)
Invokes the Bedrock SRE Agent with full context
"""

import json
import os
import boto3
import uuid
import logging
from datetime import datetime, timedelta

logger = logging.getLogger()
logger.setLevel(logging.INFO)

bedrock_agent_runtime = boto3.client("bedrock-agent-runtime")
cloudwatch_logs = boto3.client("logs")


def get_recent_pod_events(log_group: str, pod_name: str = None) -> str:
    """Fetch recent CloudWatch logs to give the agent initial context."""
    end_time = int(datetime.now().timestamp() * 1000)
    start_time = int((datetime.now() - timedelta(minutes=15)).timestamp() * 1000)

    filter_pattern = f'"{pod_name}"' if pod_name else "ERROR"

    try:
        response = cloudwatch_logs.filter_log_events(
            logGroupName=log_group,
            startTime=start_time,
            endTime=end_time,
            filterPattern=filter_pattern,
            limit=50,
        )
        events = response.get("events", [])
        if not events:
            return "No recent error events found in CloudWatch logs."
        return "\n".join([e["message"] for e in events[-20:]])  # last 20 lines
    except Exception as e:
        logger.error(f"Error fetching CloudWatch logs: {e}")
        return f"Could not fetch logs: {str(e)}"


def lambda_handler(event, context):
    logger.info(f"Received event: {json.dumps(event)}")

    agent_id = os.environ["BEDROCK_AGENT_ID"]
    agent_alias = os.environ.get("BEDROCK_AGENT_ALIAS", "TSTALIASID")
    cluster_name = os.environ["EKS_CLUSTER_NAME"]
    log_group = os.environ["LOG_GROUP_NAME"]

    # Parse SNS → CloudWatch alarm payload
    sns_message = {}
    if "Records" in event:
        for record in event["Records"]:
            if record.get("EventSource") == "aws:sns":
                sns_message = json.loads(record["Sns"]["Message"])
                break

    alarm_name = sns_message.get("AlarmName", "UnknownAlarm")
    alarm_desc = sns_message.get("AlarmDescription", "")
    namespace = sns_message.get("Trigger", {}).get("Dimensions", [{}])[0].get("value", "default")

    # Extract pod name from alarm if possible
    pod_name = None
    for dim in sns_message.get("Trigger", {}).get("Dimensions", []):
        if dim.get("name") == "PodName":
            pod_name = dim.get("value")

    # Fetch recent logs for context
    recent_logs = get_recent_pod_events(log_group, pod_name)

    # Build the agent prompt
    prompt = f"""
A Kubernetes pod failure has been detected on cluster '{cluster_name}'.

ALERT DETAILS:
- Alarm: {alarm_name}
- Description: {alarm_desc}
- Namespace: {namespace}
- Pod: {pod_name or "Unknown — please list failing pods"}
- Timestamp: {datetime.utcnow().isoformat()}Z

RECENT CLOUDWATCH LOGS:
{recent_logs}

Please diagnose and remediate this issue. Follow your SRE protocol:
1. Get pod logs and describe the failing pod
2. Search runbooks for the matching error pattern
3. Execute the appropriate fix
4. Verify the pod recovers
5. Return a structured report with RootCause, ActionTaken, Outcome
""".strip()

    session_id = str(uuid.uuid4())

    try:
        logger.info(f"Invoking Bedrock Agent {agent_id} with session {session_id}")
        response = bedrock_agent_runtime.invoke_agent(
            agentId=agent_id,
            agentAliasId=agent_alias,
            sessionId=session_id,
            inputText=prompt,
            enableTrace=True,  # Shows the agent's thought process (great for the video!)
        )

        # Stream and collect the response
        completion = ""
        traces = []

        for event_chunk in response["completion"]:
            if "chunk" in event_chunk:
                chunk_data = event_chunk["chunk"]["bytes"].decode("utf-8")
                completion += chunk_data
                logger.info(f"Agent chunk: {chunk_data[:200]}")

            if "trace" in event_chunk:
                trace = event_chunk["trace"]
                traces.append(trace)
                logger.info(f"Agent trace: {json.dumps(trace, default=str)[:500]}")

        result = {
            "statusCode": 200,
            "agentResponse": completion,
            "sessionId": session_id,
            "traceCount": len(traces),
            "timestamp": datetime.utcnow().isoformat(),
        }

        logger.info(f"Agent completed. Response length: {len(completion)} chars, Traces: {len(traces)}")
        return result

    except Exception as e:
        logger.error(f"Bedrock agent invocation failed: {e}")
        return {
            "statusCode": 500,
            "error": str(e),
            "sessionId": session_id,
        }
