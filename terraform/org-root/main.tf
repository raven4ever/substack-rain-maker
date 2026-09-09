# Guardrails, second pass. The first pass is scripts/validate.py in CI, which
# produces the rich developer-facing message. This precondition is the backstop:
# terse, but impossible to skip, because it runs inside the plan (ADR 0005).
#
# Nothing in this configuration depends on this resource. It does not need to:
# a failed precondition aborts the whole plan, so no Atlas resource is reached.
resource "terraform_data" "guardrails" {
  input = local.all_violations

  lifecycle {
    precondition {
      condition     = length(local.all_violations) == 0
      error_message = "Guardrail violations:\n  ${join("\n  ", local.all_violations)}\n\nRun scripts/validate.py locally for the full message and the owning team."
    }
  }
}
