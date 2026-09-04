"""
Network + CI/CD architecture diagram for the ECS Fargate blue/green lab.
Generated with the `diagrams` library (diagram-as-code), per the lab's
deliverable requirement. Run with:

    pip install diagrams --break-system-packages
    python architecture.py

Outputs architecture.png in this directory.
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import ECS, Fargate
from diagrams.aws.network import (
    ALB,
    VPC,
    InternetGateway,
    NATGateway,
    PrivateSubnet,
    PublicSubnet,
    Endpoint,
)
from diagrams.aws.devtools import Codepipeline, Codedeploy
from diagrams.aws.storage import S3
from diagrams.aws.management import Cloudwatch
from diagrams.aws.security import IAM
from diagrams.aws.integration import Eventbridge
from diagrams.onprem.vcs import Github
from diagrams.onprem.ci import GithubActions
from diagrams.generic.place import Datacenter

graph_attr = {
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.5",
    "splines": "spline",
}

with Diagram(
    "ECS Fargate Blue-Green CI/CD Lab",
    filename="architecture",
    show=False,
    direction="LR",
    graph_attr=graph_attr,
):

    with Cluster("GitHub"):
        infra_repo = Github("ecs-bluegreen-lab-infra")
        app_repo = Github("ecs-bluegreen-lab-app")
        infra_action = GithubActions("package-templates.yml\n(OIDC, job_workflow_ref-scoped)")
        app_action = GithubActions("build-and-push.yml\n(OIDC, job_workflow_ref-scoped)")
        infra_repo >> infra_action
        app_repo >> app_action

    with Cluster("AWS Account / Region"):

        iam_oidc = IAM("GitHub OIDC\nprovider + roles")

        templates_bucket = S3("CFN templates\nbucket")
        infra_action >> Edge(label="upload nested\ntemplates (OIDC)") >> templates_bucket

        with Cluster("VPC (multi-AZ)"):
            igw = InternetGateway("Internet\nGateway")

            with Cluster("Public Subnets (AZ-1 / AZ-2)"):
                nat = NATGateway("NAT GW")
                alb = ALB("Application\nLoad Balancer")

            with Cluster("Private Subnets (AZ-1 / AZ-2)"):
                with Cluster("ECS Cluster (Fargate)"):
                    svc_blue = Fargate("Task(s)\nBLUE")
                    svc_green = Fargate("Task(s)\nGREEN")

                with Cluster("Interface VPC Endpoints"):
                    ecr_api_ep = Endpoint("ecr.api")
                    ecr_dkr_ep = Endpoint("ecr.dkr")
                    logs_ep = Endpoint("logs")
                    sts_ep = Endpoint("sts")

            igw >> alb
            alb >> Edge(label="prod listener :80") >> svc_blue
            alb >> Edge(label="traffic shifts here\non deploy", style="dashed") >> svc_green
            svc_blue >> ecr_dkr_ep
            svc_green >> ecr_dkr_ep

        ecr_repo = S3("ECR repo\n(app image)")
        [ecr_api_ep, ecr_dkr_ep] >> ecr_repo
        logs_ep >> Cloudwatch("CloudWatch\nLogs")

        eventbridge = Eventbridge("EventBridge rule\n(ECR PUSH sha-*, IMMUTABLE)")
        pipeline = Codepipeline("CodePipeline")
        codedeploy = Codedeploy("CodeDeploy\n(blue/green)")

        app_action >> Edge(label="docker push\n:sha-xxx only (OIDC)") >> ecr_repo
        ecr_repo >> Edge(label="PutImage event\n(digest -> source override)") >> eventbridge
        eventbridge >> Edge(label="StartPipelineExecution") >> pipeline
        app_repo >> Edge(label="source: appspec.yaml\n+ taskdef.json\n(DetectChanges: false)", style="dotted") >> pipeline
        pipeline >> codedeploy
        codedeploy >> Edge(label="register new task def,\nshift ALB traffic") >> svc_green

        templates_bucket >> Edge(label="Git sync deploys\nroot.yaml", style="bold") >> Datacenter("CloudFormation\nnested stacks")
