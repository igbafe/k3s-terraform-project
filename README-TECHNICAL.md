# Developer and Terraform Reference

This document explains how the configuration is assembled and what each source file contributes. Terraform loads every `.tf` file in this directory as one module; the numeric prefixes make the files easier to read but do not determine execution order. Terraform builds its execution graph from references and `depends_on` declarations.

## Architecture and provisioning sequence

1. Terraform initializes its S3 backend and AWS, TLS, local, Helm, and Kubernetes providers.
2. The VPC, public/private subnets, gateways, routes, and security groups are created.
3. Terraform generates an SSH key pair and creates the Ubuntu master. A file provisioner copies `scripts/k3s-master.sh`; a remote-exec provisioner runs it over SSH.
4. The master script installs k3s with its built-in Traefik disabled, sets its public address as the API TLS SAN and external IP, and prepares a node token and remote kubeconfig for download. Terraform's local-exec provisioners use `scp` to download those files.
5. Terraform uploads the token and kubeconfig to S3. Worker instances run `scripts/k3s-worker.sh` with the master private IP and S3-sourced token, joining the cluster.
6. Helm and Kubernetes providers read the kubeconfig from S3. Terraform installs NGINX Ingress, cert-manager and the local ClusterIssuer chart, then Argo CD.
7. The Argo CD chart intentionally does not create an Ingress. Once DNS points to the ingress address, an operator applies `manifests/argocd-ingress.yaml` to expose Argo CD over HTTPS.

The S3 bucket has two roles: Terraform's backend stores state at `k3s/terraform.tfstate` (with S3 lockfile locking), while managed S3 objects store `k3s/node-token` and `k3s/kubeconfig`.

The workflow comments describe a bootstrap apply targeting `aws_s3_object.kubeconfig` and `aws_instance.ec2_instance_worker`, followed by an un-targeted apply for add-ons. This staged approach is necessary on a clean install: the Helm and Kubernetes provider configuration uses the cluster endpoint and certificates from the S3 kubeconfig, but that object is produced only after the master has been applied. Terraform requires provider configuration values to be known before planning resources that use those providers. Therefore, a single full plan is not available for the first deployment. After the bootstrap apply creates the kubeconfig, a normal full plan can include the cluster add-ons. The workflow currently has its apply commands commented out; review the live configuration and plan before deploying.

## File inventory

### Terraform configuration

| File | Function and rationale |
| --- | --- |
| `00-provider.tf` | Declares the S3 backend, provider source/version constraints, AWS region, and Helm/Kubernetes provider authentication. It reads and decodes the kubeconfig object from S3 and supplies the API endpoint and client certificates to both cluster providers. Backend bucket/key/region are literals because Terraform does not allow variables in a backend block. |
| `01-vpc.tf` | Creates the `10.0.0.0/16` VPC. This is the private address space shared by the cluster network resources. |
| `02-public-sub.tf` | Looks up available AZs and creates two `/24` public subnets. It maps public IPs on launch, adds Kubernetes load balancer discovery tags, and associates both subnets with the VPC main route table. |
| `03-private-sub.tf` | Creates two private `/24` subnets, a VPC Elastic IP, a NAT Gateway in public subnet 1, and a private route table with a default route through NAT. This supports outbound access for resources placed in those subnets. Current EC2 instances are not placed there. |
| `04-igw.tf` | Attaches an Internet Gateway to the VPC, giving public subnets a gateway target for internet routes. |
| `05-main-route-table.tf` | Looks up the VPC's main route table. It does not create a separate public route table. |
| `06-internet-gateway-attach.tf` | Adds a `0.0.0.0/0` route from the main route table to the Internet Gateway. |
| `07-security.tf` | Defines a general security group and a k3s-specific group. The general group allows inbound TCP 22, 80, 443, and 3000 from anywhere. The k3s group allows API TCP 6443 and NodePort TCP 30000–32767 from anywhere, all protocols between members of that group, and all outbound traffic. |
| `08-keypair.tf` | Generates a 4096-bit RSA private key using the TLS provider and registers its public half as an EC2 key pair. The private half is written locally by the sensitive-file resource in `12-outputs.tf`. |
| `09-k3s-master.tf` | Selects the latest Canonical Ubuntu 24.04 AMD64 AMI, defines the cluster name, creates the master EC2 instance, and runs the master script over SSH. After provisioning, local `scp` provisioners fetch the node token and kubeconfig. Explicit dependencies keep network routes and access rules available while the instance is provisioned and removed. |
| `10-k3s-workers.tf` | Creates `worker_count` EC2 instances, alternates them between the two public subnets, and runs the worker install script over SSH. Workers join the master's private IP using the token read from S3. Each gets a public IP as its k3s external IP. |
| `11-upload-sensitive.tf` | Uploads the local token and kubeconfig to S3 using AES-256 server-side encryption. It then reads the token back for worker provisioning. The objects are replaced when the master instance changes. |
| `12-outputs.tf` | Writes the generated SSH private key to `my-ec2-key.pem` with restrictive file permissions and exposes useful IPs, SSH commands, kubeconfig/S3 paths, ingress address, Argo CD URL, and initial admin credentials. The password output is marked sensitive; Terraform state still contains sensitive configuration data and must be protected. |
| `13-nginx-ingress.tf` | Labels the master for k3s ServiceLB, installs the NGINX Ingress Controller Helm chart, configures the ingress class, and reads back its LoadBalancer service address. `externalTrafficPolicy = Cluster` allows ServiceLB on the master to forward traffic to NGINX pods on any node. |
| `14-cert-manager.tf` | Installs cert-manager with CRDs enabled, then installs the local `cluster-issuer` Helm chart with the configured Let's Encrypt email and `nginx` ingress class. |
| `15-argocd.tf` | Installs Argo CD from the Argo Helm repository with its configured domain. Argo CD serves plain HTTP inside the cluster because TLS is terminated by NGINX. Its chart-managed Ingress is disabled; the initial admin secret is read for the Terraform output. |
| `variable.tf` | Defines tunable instance sizes, worker count, S3 bucket, Argo CD hostname, and Let's Encrypt email, with defaults. The bucket default must match the literal backend bucket in `00-provider.tf`. |
| `.terraform.lock.hcl` | Locks provider selections and package checksums so Terraform can reproduce provider installations. Commit this file; update it through Terraform's provider initialization workflow when intentionally upgrading. |

### Scripts, chart, manifest, and automation

| File | Function and rationale |
| --- | --- |
| `scripts/k3s-master.sh` | Runs on Ubuntu as root. Sets the node hostname, installs the k3s server with Traefik disabled and the public IP configured, waits for the server token, then copies the token and a public-address kubeconfig into the `ubuntu` home directory with restricted permissions. |
| `scripts/k3s-worker.sh` | Runs on each worker as root. Sets its hostname and installs the k3s agent with `K3S_URL` targeting the master private IP and `K3S_TOKEN` for cluster authentication. |
| `charts/cluster-issuer/Chart.yaml` | Helm chart metadata for the local ClusterIssuer chart. |
| `charts/cluster-issuer/values.yaml` | Default values for the issuer email and ingress class; Terraform overrides them when installing the chart. |
| `charts/cluster-issuer/templates/cluster-issuer.yaml` | Renders staging and production Let's Encrypt ClusterIssuers using HTTP-01 challenges served by the NGINX ingress class. |
| `manifests/argocd-ingress.yaml` | Kubernetes Ingress definition for the Argo CD service. It requests a production Let's Encrypt certificate and stores it in `argocd-server-tls`. It is deliberately applied manually after DNS setup. |
| `.github/workflows/deploy.yml` | GitHub Actions workflow for `main` pushes affecting Terraform/scripts/charts/workflow and manual dispatch. It assumes an AWS role using GitHub OIDC, installs Terraform 1.16.5, initializes, formats-checks, and validates. Apply/destroy commands are present only as comments, so neither dispatch option currently mutates infrastructure. |
| `repo-org-id-gen.sh` | Optional helper that prompts for a GitHub PAT, queries the GitHub API for the hard-coded organization and repository, and prints their numeric IDs. Its output can be used when setting up repository/organization-scoped GitHub OIDC trust. It does not configure AWS or GitHub. |
| `.gitignore` | Excludes Terraform working data/state, variable files, crash logs, the generated PEM key, node token, and kubeconfig. |
| `README.md` | General project overview and operator quick start. |
| `README-TECHNICAL.md` | This file: developer-oriented architecture, resource behavior, and implementation notes. |

## Inputs and dependencies

Defaults in `variable.tf` are:

| Variable | Default | Effect |
| --- | --- | --- |
| `master_instance_type` | `t2.medium` | EC2 size for the k3s server. The variable description calls for at least 2 GB RAM. |
| `worker_instance_type` | `t2.small` | EC2 size for each worker. |
| `worker_count` | `1` | Number of worker instances; instances are distributed alternately over the two public subnets. |
| `s3_bucket` | `terrformstate-060647991200` | Bucket for the Terraform-managed node token and kubeconfig. It must also match the S3 backend bucket literal. |
| `argocd_hostname` | `argocd.digitalwitch.online` | Domain placed into the Argo CD Helm configuration and output URL. |
| `letsencrypt_email` | `chukwunonsosmartagbawo@gmail.com` | Contact email passed to the local ClusterIssuer chart. |

The AWS region is hard-coded as `us-west-1` in both the backend and AWS provider configuration. The bucket must already exist before `terraform init`; this repository does not create it. AWS credentials must permit backend state/lockfile access and management of EC2, VPC, security groups, routes, EIPs, NAT, key pairs, and S3 objects. The Terraform runner also needs SSH/SCP access to newly created EC2 public IPs. The GitHub workflow expects an `AWS_OID_ARN` Actions secret containing the role ARN and an AWS role trust policy that accepts the repository's GitHub OIDC identity.

The `.terraform.lock.hcl` currently selects AWS provider 6.68.0, Helm 3.3.0, Kubernetes 2.38.0, local 2.9.1, and TLS 4.4.1, within the constraints declared in `00-provider.tf`.

## Deployment and lifecycle

For local work, authenticate to AWS, set desired Terraform inputs with `TF_VAR_<name>` environment variables or a local `.tfvars` file (which is ignored by Git), then initialize. The workflow's commented commands indicate this two-pass shape for a new cluster:

```bash
terraform init -input=false
terraform plan -input=false -target=aws_s3_object.kubeconfig -target=aws_instance.ec2_instance_worker -out=bootstrap.tfplan
terraform apply -input=false bootstrap.tfplan
terraform plan -input=false -out=cluster.tfplan
```

Targeted planning is an explicit bootstrap technique in this repository; inspect its plan and Terraform's targeting warnings. The first pass must create the master and the access files in S3, plus workers. The subsequent full plan can then configure the Kubernetes providers and show the Helm/Kubernetes add-ons. Apply `cluster.tfplan` only after reviewing it. The GitHub workflow currently does not run these commands, even though push events set an `ACTION` environment value and manual dispatch offers `apply`/`destroy` choices.

After apply:

1. Read `terraform output` and point the desired DNS A record(s) to `load_balancer_ip`.
2. Ensure `argocd_hostname` matches the host in `manifests/argocd-ingress.yaml`. The checked-in manifest currently uses `arg.digitalwitch.online`, while the Terraform default is `argocd.digitalwitch.online`.
3. Once DNS resolves, apply the manifest with `kubectl apply -f manifests/argocd-ingress.yaml` using the generated kubeconfig. The manifest currently selects the production issuer, so use the staging issuer while validating DNS/challenge behavior if appropriate.
4. Retrieve the initial Argo CD password from `terraform output -raw argocd_initial_admin_password` if it still exists. Argo CD may delete that secret after the first login.

Destroying the Terraform-managed infrastructure removes the EC2/VPC/add-on resources and managed S3 objects, but it does not remove the pre-existing backend bucket. Keep a copy of any needed kubeconfig before destroy. Generated local files such as the private key may remain and should be handled securely.

## Implementation constraints and review items

- **Public placement:** `10-k3s-workers.tf` selects `aws_subnet.public_subnet_01` and `aws_subnet.public_subnet_02`; the master also uses public subnet 1. The private subnets and NAT Gateway exist but currently have no cluster instances attached.
- **Broad inbound access:** SSH (22), Kubernetes API (6443), HTTP/HTTPS, TCP 3000, and the full NodePort range include `0.0.0.0/0` sources. Limit these to trusted CIDRs and required consumers for any shared or production environment.
- **Secret handling:** The SSH private key, k3s token, kubeconfig client certificate/key, and initial Argo CD password are sensitive. The S3 objects use AES-256 server-side encryption, but state and object access permissions still determine confidentiality. Terraform's `sensitive` output flag redacts normal CLI display; it does not remove the value from state. Restrict and encrypt state access, and avoid printing tokens in CI logs.
- **Ingress hostname mismatch:** `argocd_hostname` defaults to `argocd.digitalwitch.online`, while the checked-in manifest routes `arg.digitalwitch.online`. These must be aligned or the requested host will not route correctly.
- **CI does not deploy today:** `.github/workflows/deploy.yml` has its apply/destroy steps commented out. Its `workflow_dispatch` menu currently does not cause either action to run.
- **Hard-coded shared settings:** The region and S3 backend bucket are literals in `00-provider.tf`; changing `s3_bucket` alone does not move Terraform state. Backend migration requires updating the backend configuration and intentionally reinitializing/migrating state.
- **Generated credentials and state:** The local private key and downloaded kubeconfig/token are ignored by Git, but they still exist on the runner/workstation. Protect and remove local copies when no longer needed.
- **Single NAT Gateway:** The configured private route table sends both private subnets through one NAT Gateway in public AZ 1. This is a cost and availability tradeoff if instances are later moved into private subnets.

This guide describes the checked-in configuration. Confirm provider/chart versions, Terraform plans, IAM permissions, and AWS costs against the target account before applying changes.
