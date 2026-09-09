output "workspaces" {
  description = "Workspace name per organization."
  value       = { for k, w in tfe_workspace.org : k => w.name }
}
