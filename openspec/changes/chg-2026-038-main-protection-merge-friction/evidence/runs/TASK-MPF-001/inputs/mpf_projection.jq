{
  required_status_checks: (.required_status_checks | {strict, contexts, checks}),
  required_pull_request_reviews: (.required_pull_request_reviews | {
    dismiss_stale_reviews,
    require_code_owner_reviews,
    require_last_push_approval,
    required_approving_review_count,
    dismissal_restrictions: (if has("dismissal_restrictions") then (.dismissal_restrictions | {users: [.users[] | {login, id}], teams: [.teams[] | {slug, id}], apps: [.apps[] | {slug, id}]}) else null end),
    bypass_pull_request_allowances: (if has("bypass_pull_request_allowances") then (.bypass_pull_request_allowances | {users: [.users[] | {login, id}], teams: [.teams[] | {slug, id}], apps: [.apps[] | {slug, id}]}) else null end)
  }),
  restrictions: (if has("restrictions") then (.restrictions | {users: [.users[] | {login, id}], teams: [.teams[] | {slug, id}], apps: [.apps[] | {slug, id}]}) else null end),
  required_signatures: .required_signatures.enabled,
  enforce_admins: .enforce_admins.enabled,
  required_linear_history: .required_linear_history.enabled,
  allow_force_pushes: .allow_force_pushes.enabled,
  allow_deletions: .allow_deletions.enabled,
  block_creations: .block_creations.enabled,
  required_conversation_resolution: .required_conversation_resolution.enabled,
  lock_branch: .lock_branch.enabled,
  allow_fork_syncing: .allow_fork_syncing.enabled
}
