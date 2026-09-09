locals {
  # The org list is the directory list. Onboarding an org is adding a directory.
  orgs = toset([
    for f in fileset("${path.module}/../../orgs", "*/org.yaml") : dirname(f)
  ])
}
