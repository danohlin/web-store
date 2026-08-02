#
# IAM Roles for Service Accounts.
#
# Every in-cluster component that talks to AWS assumes a role through the OIDC
# provider. No static access keys exist anywhere in the cluster.
#
# The trust policy pins both the audience and the exact namespace/serviceaccount
# pairs. Without the sub condition, any pod in the cluster could assume the role
# simply by naming it.
#

locals {
  oidc_provider_arn = aws_iam_openid_connect_provider.cluster.arn
  oidc_provider_url = replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")

  # Each role maps to the set of service accounts allowed to assume it.
  #
  # The application role trusts two: the API's service account and the one the
  # Helm pre-install migration hook creates. They must share a role because the
  # chart exposes a single serviceAccount.roleArn for both.
  irsa_subjects = {
    alb_controller = ["kube-system:aws-load-balancer-controller"]
    csi_driver     = ["kube-system:secrets-store-csi-driver-provider-aws"]
    app = [
      "${var.k8s_namespace}:${var.project}",
      "${var.k8s_namespace}:${var.project}-migrate",
    ]
  }
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa_subjects

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = [for sa in each.value : "system:serviceaccount:${sa}"]
    }
  }
}

# ------------------------------------------------------- alb controller role

resource "aws_iam_role" "alb_controller" {
  name_prefix        = "${local.name}-alb-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["alb_controller"].json

  tags = {
    Name = "${local.name}-alb-controller"
  }
}

# Vendored from kubernetes-sigs/aws-load-balancer-controller v2.11.0 rather
# than hand-written: it is 16 statements of fine-grained ELB and EC2
# permissions, and an omission surfaces as a controller that silently fails to
# create a load balancer.
resource "aws_iam_policy" "alb_controller" {
  name_prefix = "${local.name}-alb-"
  description = "AWS Load Balancer Controller (upstream policy v2.11.0)"
  policy      = file("${path.module}/policies/alb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ----------------------------------------------------------- csi driver role

# Assumed by the Secrets Store CSI driver's AWS provider. It reads the same two
# secrets, on behalf of the pods that mount them.
resource "aws_iam_role" "csi_driver" {
  name_prefix        = "${local.name}-csi-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["csi_driver"].json

  tags = {
    Name = "${local.name}-csi-driver"
  }
}

resource "aws_iam_role_policy_attachment" "csi_driver_secrets" {
  role       = aws_iam_role.csi_driver.name
  policy_arn = aws_iam_policy.read_app_secrets.arn
}

# ------------------------------------------------------------------ app role

data "aws_iam_policy_document" "read_app_secrets" {
  statement {
    sid    = "ReadOwnSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    # Scoped to exactly the two secrets this application owns. A wildcard here
    # would let the workload read every secret in the account.
    resources = [
      aws_secretsmanager_secret.database.arn,
      aws_secretsmanager_secret.app.arn,
    ]
  }
}

resource "aws_iam_policy" "read_app_secrets" {
  name_prefix = "${local.name}-secrets-"
  description = "Read the web-store database and application secrets"
  policy      = data.aws_iam_policy_document.read_app_secrets.json
}

resource "aws_iam_role" "app" {
  name_prefix        = "${local.name}-app-"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["app"].json

  tags = {
    Name = "${local.name}-app"
  }
}

resource "aws_iam_role_policy_attachment" "app_secrets" {
  role       = aws_iam_role.app.name
  policy_arn = aws_iam_policy.read_app_secrets.arn
}
