"""Render docs/architecture.png with the official AWS Architecture Icons.

The icons are not bundled in this repository. Download the current
"Architecture Icons" asset package from https://aws.amazon.com/architecture/icons/,
unzip it (and the zip files inside it), and point AWS_ICONS at the folder that
contains Architecture-Service-Icons_<date> and Resource-Icons_<date>.

    pip install diagrams          # also needs Graphviz: brew install graphviz
    AWS_ICONS=/path/to/icon-package python docs/architecture_diagram.py
"""

import glob
import os
import sys

from diagrams import Cluster, Diagram, Edge
from diagrams.custom import Custom

ICONS = os.environ.get("AWS_ICONS")
if not ICONS or not os.path.isdir(ICONS):
    sys.exit("Set AWS_ICONS to the unzipped AWS Architecture Icons package folder.")


def icon(pattern: str) -> str:
    """Return the one icon file in the package that matches pattern."""
    hits = [h for h in glob.glob(os.path.join(ICONS, "**", pattern), recursive=True)
            if "__MACOSX" not in h]
    if len(hits) != 1:
        sys.exit(f"Expected exactly one icon for {pattern!r}, found {len(hits)}.")
    return hits[0]


SVC = "Arch_{}_64.png"
AGENTCORE = icon(SVC.format("Amazon-Bedrock-AgentCore"))
S3 = icon(SVC.format("Amazon-Simple-Storage-Service"))
ECR = icon(SVC.format("Amazon-Elastic-Container-Registry"))
FARGATE = icon(SVC.format("AWS-Fargate"))
CLOUDWATCH = icon(SVC.format("Amazon-CloudWatch"))
ELB = icon(SVC.format("Elastic-Load-Balancing"))
DYNAMODB = icon(SVC.format("Amazon-DynamoDB"))
SNS = icon(SVC.format("Amazon-Simple-Notification-Service"))
LAMBDA = icon(SVC.format("AWS-Lambda"))
SECURITY_AGENT = icon(SVC.format("AWS-Security-Agent"))
DEVOPS_AGENT = icon(SVC.format("AWS-DevOps-Agent"))
USER = icon("Res_User_48_Light.png")

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "architecture")

GRAPH = {"fontsize": "20", "labelloc": "t", "pad": "0.4", "nodesep": "0.9", "ranksep": "1.0", "splines": "spline",
         "fontname": "Helvetica"}
NODE = {"fontsize": "13", "fontname": "Helvetica"}
EDGE = {"fontsize": "13", "fontname": "Helvetica"}
GREY = "#7d8998"

with Diagram(
    "DevOps-orchestrated security investigation — cross-domain A2A handoff\n"
    "(sandbox only · single region · educational · MIT-0)",
    filename=OUT, outformat="png", show=False, direction="LR",
    graph_attr=GRAPH, node_attr=NODE, edge_attr=EDGE,
):
    with Cluster("Managed AWS agents", graph_attr={"bgcolor": "#E6F2FA"}):
        devops = Custom("AWS DevOps Agent\n(investigates, delegates)", DEVOPS_AGENT)
        security = Custom("AWS Security Agent\n(differential code review)", SECURITY_AGENT)

    operator = Custom("Operator\n(approves; nothing auto-applied)", USER)

    with Cluster("Sandbox AWS account · single region", graph_attr={"bgcolor": "#F2F8FC"}):
        with Cluster("A2A bridge — remote agent (does not modify the workload)",
                     graph_attr={"bgcolor": "#EEF5EC"}):
            bridge = Custom("AgentCore Runtime\nStrands A2A agent", AGENTCORE)
            bucket = Custom("DIFF_BUCKET\n(.patch + source ZIP)", S3)

        with Cluster("Synthetic app (deploy.sh + CloudFormation)",
                     graph_attr={"bgcolor": "#EEF5EC"}):
            ecr = Custom("ECR\n(image built locally)", ECR)
            alb = Custom("ALB", ELB)
            fargate = Custom("ECS Fargate\n(Flask app)", FARGATE)
            cloudwatch = Custom("CloudWatch\nlogs + 5xx alarm", CLOUDWATCH)
            table = Custom("DynamoDB", DYNAMODB)

        with Cluster("Incident pipeline", graph_attr={"bgcolor": "#EEF5EC"}):
            sns = Custom("SNS", SNS)
            forwarder = Custom("Forwarder\n(HMAC-signed)", LAMBDA)

    # The app and the incident pipeline.
    ecr >> Edge(color=GREY, style="dotted") >> fargate
    alb >> Edge(color=GREY) >> fargate
    fargate >> Edge(color=GREY) >> cloudwatch
    fargate >> Edge(color=GREY) >> table
    cloudwatch >> Edge(color=GREY, label="5xx") >> sns
    sns >> Edge(color=GREY) >> forwarder

    # The numbered agent flow.
    forwarder >> Edge(color="darkorange", fontcolor="darkorange", label="(1) incident webhook") >> devops
    devops >> Edge(color="firebrick", fontcolor="firebrick", label="(2) A2A delegate") >> bridge
    bridge >> Edge(color=GREY, style="dotted", label="stage diff") >> bucket
    bridge >> Edge(color="darkgreen", fontcolor="darkgreen", label="(3) start review") >> security
    security >> Edge(color="darkgreen", fontcolor="darkgreen", style="dashed", label="(4) findings") >> bridge
    bridge >> Edge(color="firebrick", fontcolor="firebrick", style="dashed", label="(5) findings -> one timeline") >> devops
    devops >> Edge(color=GREY, fontcolor=GREY, style="dotted", xlabel="review") >> operator
