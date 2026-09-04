# ecs-bluegreen-lab-infra

All infrastructure for the **ECS Fargate Blue/Green CI/CD lab**: a highly
available, containerized fullstack Java app on **Amazon ECS Fargate**, in
a custom multi-AZ VPC, behind a public ALB, deployed via **CodePipeline +
CodeDeploy blue/green**, triggered automatically by container image
pushes. All infrastructure is **CloudFormation**, deployed via **Git
sync**; all CI/CD-to-AWS calls use **OIDC**.

The application code lives in a separate repo:
[`ecs-bluegreen-lab-app`](https://github.com/1MuhireDavid/ecs-bluegreen-lab-app).

```
ecs-bluegreen-lab-infra/
├── README.md                    (this file)
├── cfn/
│   ├── root.yaml                  # master template -- what Git sync deploys
│   ├── deployment-file.yaml        # Git sync's parameters/tags file
│   ├── bootstrap/
│   │   ├── 00-bootstrap.yaml          # deployed ONCE, manually (see below)
│   │   └── 00-bootstrap.deploy.yaml    # optional: deploy the bootstrap stack via Git sync too
│   └── modules/
│       ├── 01-network.yaml         # VPC, public+private subnets x2 AZ, NAT
│       ├── 02-security.yaml         # least-privilege security groups
│       ├── 03-ecr-endpoints.yaml      # ECR repo + interface/gateway VPC endpoints
│       ├── 04-alb-ecs.yaml               # ALB, ECS cluster/service, autoscaling
│       └── 05-cicd-pipeline.yaml          # CodePipeline, CodeDeploy, EventBridge
├── scripts/bootstrap.sh          # one-time bootstrap helper (optional CLI alternative)
├── diagram/architecture.py       # diagram-as-code
└── .github/workflows/
    ├── package-templates.yml        # OIDC upload of cfn/modules/** to S3, bump TemplatesVersion
    └── infra-deploy.yml               # manual Git sync fallback (see below)
```

## Architecture

- **Network:** 1 VPC, 2 AZs, 2 public + 2 private subnets, 1 NAT Gateway
  (parameterized to 2 for full HA egress).
- **Compute:** ECS Fargate tasks in **private** subnets only, no public
  IPs. Pulled images, shipped logs, and STS calls all travel over
  **interface VPC endpoints** (`ecr.api`, `ecr.dkr`, `logs`, `sts`) plus a
  free **S3 gateway endpoint** for ECR's underlying layer storage --
  steady-state traffic never needs the NAT Gateway.
- **Exposure:** a public **ALB** is the only internet-facing resource;
  security groups form a strict chain (Internet -> ALB SG -> ECS task SG
  -> VPC endpoint SG), least privilege at every hop.
- **Scaling:** target-tracking on `ECSServiceAverageCPUUtilization`,
  1 (min) / 1 (desired) / 4 (max) tasks.
- **Deploy:** ECS service uses `DeploymentController: CODE_DEPLOY`.
  The ECR repo is **immutable** -- every build pushes exactly one
  never-reused `sha-<gitsha>` tag, so there's no floating `:latest`
  pointer. EventBridge instead watches for *any* successful `sha-*` push
  and passes the exact image **digest** into CodePipeline as a
  source-revision override, so the pipeline always deploys the specific
  image that triggered it. CodePipeline hands that image + `appspec.yaml`/
  `taskdef.json` (pulled from the **app repo**) to CodeDeploy for a
  blue/green traffic shift. The pipeline's GitHub source action has
  `DetectChanges: false` deliberately, so it never self-triggers on an
  unrelated app-repo commit (e.g. a README edit) -- EventBridge is the
  sole trigger.
- **IaC delivery:** CloudFormation **Git sync** deploys `cfn/root.yaml`
  straight from this repo on every push to `main`; nested stack templates
  are hosted in S3 (bucket created by a one-time bootstrap stack) since
  Git sync has no built-in `cfn package` step.
- **CI/CD auth:** this repo's workflow authenticates to AWS via **OIDC**
  (`sts:AssumeRoleWithWebIdentity`), scoped to this exact repo + workflow
  file; the app repo's build workflow does the same, independently scoped
  to itself. Zero stored AWS keys in either repo.

## Why nested stacks are hosted in S3

`root.yaml` references each module via `TemplateURL` pointing at S3
(required by nested stacks, and explicitly requested by the lab spec).
Git sync deploys `root.yaml` **as-is** -- it does not run `aws
cloudformation package`, so there's no automatic step that uploads
`cfn/modules/*.yaml` anywhere. This repo closes that gap itself:

1. `.github/workflows/package-templates.yml` runs on every push that
   touches `cfn/modules/**`. It authenticates to AWS **via OIDC** (no
   long-lived secrets) and uploads the modules to
   `s3://<bucket>/templates/<git-short-sha>/`.
2. It then bumps `TemplatesVersion` in `deployment-file.yaml` to that
   same short SHA and commits the change back to `main`.
3. That commit is what Git sync actually watches -- so a
   nested-template-only change still produces a real parameter change
   on `root.yaml`, guaranteeing CloudFormation re-resolves the child
   templates (rather than relying on it noticing an S3 object changed
   under an unchanged URL).

## Git sync vs. GitHub Actions OIDC -- two different auth mechanisms, on purpose

| System | Direction | Auth mechanism |
|---|---|---|
| This repo's `package-templates.yml` | GitHub -> AWS | **OIDC** federated role, scoped to this repo + workflow file |
| `ecs-bluegreen-lab-app`'s `build-and-push.yml` | GitHub -> AWS | **OIDC** federated role, scoped to *that* repo + workflow file |
| CloudFormation Git sync | AWS -> this repo (AWS reads this repo to deploy it) | AWS's native **CodeConnections** (GitHub App install) |
| CodePipeline's GitHub source action | AWS -> `ecs-bluegreen-lab-app` (AWS reads that repo for `appspec.yaml`/`taskdef.json`) | The **same** CodeConnections connection, authorized against the app repo |

Both are secretless/keyless from GitHub's side; only the first two are
literally "OIDC" in the IAM sense, since OIDC federation only makes sense
for the direction where GitHub Actions is the caller.

## One-time bootstrap

`cfn/bootstrap/00-bootstrap.yaml` creates the S3 templates bucket, the
`token.actions.githubusercontent.com` OIDC provider (a **singleton per
AWS account** -- leave `CreateOidcProvider` at `false` if any other lab
in this account already created one), and three scoped OIDC roles -- one
per repo, plus one manual-deploy fallback role (see below). Deployed
once, manually, **not** through Git sync, because an OIDC provider must
never be at risk of being deleted/recreated by a routine app or infra
change.

**Deploy it via the AWS Console** (no CLI needed):

1. Sign in to the **AWS Console** and pick your target Region in the
   top-right region selector -- everything else in this lab deploys into
   whatever region you pick here, so note it down.
2. *(Skip if you already know GitHub OIDC is set up in this account from
   another lab.)* Go to **IAM -> Identity providers**. If
   `token.actions.githubusercontent.com` is already listed, keep
   `CreateOidcProvider` at `false` in step 5.
3. Go to **CloudFormation -> Stacks -> Create stack -> With new resources
   (standard)**.
4. Under **Specify template**, choose **Upload a template file -> Choose
   file**, and select `cfn/bootstrap/00-bootstrap.yaml` from your local
   clone. Click **Next**.
5. **Stack name:** `ecs-bluegreen-lab-bootstrap`. Fill in the parameters:

   | Parameter | Value |
   |---|---|
   | ProjectName | `ecs-bluegreen-lab` (default) |
   | GitHubOrg | `1MuhireDavid` |
   | InfraRepoName | `ecs-bluegreen-lab-infra` (default) |
   | AppRepoName | `ecs-bluegreen-lab-app` (default) |
   | AllowedGitRef | `refs/heads/main` (default) |
   | InfraPackagingWorkflowFile / AppBuildWorkflowFile / InfraDeployWorkflowFile | leave defaults unless you renamed a workflow file |
   | CreateOidcProvider | `false` unless step 2 found no existing provider |

   Click **Next**.
6. **Configure stack options:** leave everything at its default (add
   tags here if your account requires them). Click **Next**.
7. On the **Review** page, scroll to the **Capabilities** box at the
   bottom and check **"I acknowledge that AWS CloudFormation might
   create IAM resources with custom names."** This is required because
   the template creates three named IAM roles. Click **Submit**.
8. Wait for the stack status to reach **CREATE_COMPLETE** (S3 + IAM only,
   typically under two minutes).

   > **If a bucket-already-exists error appears:** `TemplatesBucket` has
   > `DeletionPolicy: Retain`, so if this lab was ever deployed before
   > (even under a different repo layout) and the stack was later
   > deleted, the bucket from that earlier deployment may still exist
   > under the same deterministic name
   > (`ecs-bluegreen-lab-cfn-templates-<account>-<region>`). Either
   > delete that leftover bucket first, or just reuse its name directly
   > in `cfn/deployment-file.yaml`'s `TemplatesBucketName` and skip
   > re-creating it.
9. Click into the stack and open its **Outputs** tab. You'll need
   `TemplatesBucketName`, `InfraPackagingRoleArn`, `AppEcrPushRoleArn`,
   and `InfraDeployRoleArn` in the next steps.

*(Prefer the CLI? `scripts/bootstrap.sh <github-org> [region]` does the
same thing and prints the same output values -- either path is fine,
they create identical resources.)*

## Full setup order

1. **Deploy the bootstrap stack via the Console** -- see above. Note the
   four Output values.
2. **Add this repo's secrets** (GitHub's UI): go to
   `github.com/1MuhireDavid/ecs-bluegreen-lab-infra` -> **Settings ->
   Secrets and variables -> Actions**, and add:

   | Secret name | Value |
   |---|---|
   | `AWS_INFRA_PACKAGING_ROLE_ARN` | the `InfraPackagingRoleArn` output |
   | `AWS_TEMPLATES_BUCKET` | the `TemplatesBucketName` output |
   | `AWS_INFRA_DEPLOY_ROLE_ARN` | the `InfraDeployRoleArn` output (only needed if you ever run `infra-deploy.yml`) |

   Then under **Variables**, add `AWS_REGION` = the region you deployed
   into (step 1).
3. **Add the app repo's secrets** -- same Console flow, but on
   `github.com/1MuhireDavid/ecs-bluegreen-lab-app`:

   | Secret name | Value |
   |---|---|
   | `AWS_ECR_PUSH_ROLE_ARN` | the `AppEcrPushRoleArn` output |
   | `ECR_REPOSITORY` | `ecs-bluegreen-lab-app` |

   And `AWS_REGION` under **Variables**, same value as above.
4. **Fill in `cfn/deployment-file.yaml`** in this repo -- replace
   `TemplatesBucketName`'s placeholder with the real output value, and
   set `AppOwnerName` to your full name. `GitHubOrg`/`AppRepoName` are
   already filled in. Commit the change.
5. **Push this repo to GitHub on `main`.** `.github/workflows/
   package-templates.yml` runs automatically, uploads the nested
   templates to S3, and commits the first `TemplatesVersion` back to the
   repo -- no action needed from you here.
6. **Turn on Git sync**, entirely in the CloudFormation console:
   - **CloudFormation -> Stacks -> Create stack -> With Git sync**.
   - Connect to `1MuhireDavid/ecs-bluegreen-lab-infra`, branch `main`.
   - Deployment file path: `cfn/deployment-file.yaml`.
   - Accept the console's defaults for the Git sync service role and
     stack execution role, granting `CAPABILITY_NAMED_IAM`.
   - Git sync opens a pull request confirming the deployment file schema
     -- merge it to kick off the first deploy.
   - Watch the stack's **Events** tab; the full nested-stack deploy (VPC,
     NAT, ALB, ECS, pipeline) typically takes 10-15 minutes.

   > **If Git sync's auto-changeset repeatedly fails validation** (a
   > known issue we hit before, not obviously fixable from the repo
   > side even with every parameter correctly set) -- run
   > `.github/workflows/infra-deploy.yml` manually from the Actions tab
   > instead. It reads the same `deployment-file.yaml` and deploys via
   > `aws cloudformation deploy`, giving real error output instead of the
   > opaque Git sync console message.
7. **Authorize the GitHub connection** -- in the CloudFormation console,
   go to **Developer Tools -> Settings -> Connections**, find the
   connection created by `05-cicd-pipeline.yaml` (status **Pending**),
   click it, and **Update pending connection** to complete the one-click
   GitHub App authorization against `ecs-bluegreen-lab-app`. The
   pipeline's GitHub source action won't run until this is **Available**.
8. **Push the app** -- see `ecs-bluegreen-lab-app`'s README for filling
   in `ecs/taskdef.json` and triggering the first real image build. That
   push builds/pushes the image, EventBridge fires, CodePipeline runs,
   CodeDeploy shifts traffic blue -> green.
9. **Open the app** -- CloudFormation console -> root stack
   (`ecs-bluegreen-lab`) -> **Outputs** tab -> `AlbEndpoint`.

## Deliverables checklist

| Deliverable | Where |
|---|---|
| Infra CloudFormation | this repo |
| App code + Dockerfile + build/deploy files | [`ecs-bluegreen-lab-app`](https://github.com/1MuhireDavid/ecs-bluegreen-lab-app) |
| ALB endpoint | CloudFormation output `AlbEndpoint` on the root stack, after step 8 |
| Architecture diagram (diagram-as-code) | `diagram/architecture.py` -> `diagram/architecture.png` |

## Rubric -> implementation map

| Rubric item | Implementation |
|---|---|
| Multi-AZ VPC, correct subnets | `cfn/modules/01-network.yaml` |
| Private ECS + VPC endpoint connectivity + public ALB | `03-ecr-endpoints.yaml`, `04-alb-ecs.yaml` |
| Least-privilege security groups | `02-security.yaml` (strict SG-to-SG chain) |
| All resources via CFN + Git sync | `cfn/root.yaml` + `cfn/deployment-file.yaml` |
| GitHub Actions builds & pushes image | `ecs-bluegreen-lab-app/.github/workflows/build-and-push.yml` |
| OIDC auth (no long-lived secrets) | Both workflows use `role-to-assume`; roles + `job_workflow_ref` scoping in `cfn/bootstrap/00-bootstrap.yaml` |
| Image tagging strategy is consistent and immutable | `:sha-<gitsha>` only, `ImageTagMutability: IMMUTABLE` repo -- see `ecs-bluegreen-lab-app/README.md` |
| App accessible via ALB | `AlbEndpoint` output |
| ALB health checks pass | Health check path `/`, answered by both the bootstrap placeholder and the real app |
| CloudWatch Logs | `awslogs` driver -> `/ecs/ecs-bluegreen-lab-app` log group |
| Auto scaling 1-4 on CPU | `ScalableTarget` / `CpuScalingPolicy` in `04-alb-ecs.yaml` |
| Blue/green deployment | `05-cicd-pipeline.yaml`: CodeDeploy `BLUE_GREEN` + `WITH_TRAFFIC_CONTROL`, two target groups |

## Security & cost notes

- Every security group is scoped to the single upstream SG that should
  reach it (Internet -> ALB SG :80 -> ECS task SG :container-port -> VPC
  endpoint SG :443) -- no `0.0.0.0/0` ingress below the ALB.
- ECS tasks run in **private** subnets with `AssignPublicIp: DISABLED`;
  all outbound calls that matter (ECR, CloudWatch Logs, STS) go over
  interface VPC endpoints, and the ECR image-layer store (S3) goes over a
  free gateway endpoint -- NAT Gateway is present for other/edge-case
  internet egress (e.g. pulling the public bootstrap placeholder image)
  but ordinary steady-state traffic never touches it.
- `SingleNatGateway=true` by default (1 NAT Gateway) to keep the lab
  cheap; flip to `false` for fully-HA egress in a production setting.
- All S3 buckets: private, encrypted, versioned, deny-insecure-transport.
- IAM roles are purpose-scoped (e.g. the ECR-push role can only push to
  its own single ECR repository ARN -- it cannot touch ECS, IAM, or any
  other repository -- and is further scoped to one exact workflow file).
  The one broad exception, `InfraDeployRole` (`AdministratorAccess`), is
  a documented, `workflow_dispatch`-only fallback for a real Git sync
  issue -- not push-triggered, so it can't fire on its own.
- Every resource is tagged `Project`/`ManagedBy`/`Environment` (propagated
  from `deployment-file.yaml`'s `tags:` block through the nested stacks).

## Regenerating the diagram

```bash
pip install diagrams --break-system-packages   # also requires the `graphviz` system package
cd diagram && python3 architecture.py
```
