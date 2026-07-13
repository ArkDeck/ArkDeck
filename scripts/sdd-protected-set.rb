# frozen_string_literal: true

# Single source of truth for the Core-baseline protected file set.
#
# Both the guard (check-sdd.rb) and the candidate relock tool
# (relock-baseline.rb) MUST consume this constant. Editing this list is a
# governance change: the file itself is part of the protected set, so any
# modification requires a candidate relock before ratification and an approved
# Core change afterwards.
SDD_PROTECTED_PATTERNS = [
  "AGENTS.md",
  "openspec/README.md",
  "openspec/constitution.md",
  "openspec/project.md",
  "openspec/config.yaml",
  "openspec/governance/**/*",
  "openspec/architecture/**/*",
  "openspec/schemas/**/*",
  "openspec/templates/change/**/*",
  "openspec/changes/README.md",
  "openspec/specs/**/*",
  "openspec/contracts/*.schema.json",
  "openspec/contracts/provider-contracts.md",
  "openspec/contracts/workflow-step-registry.yaml",
  "openspec/contracts/catalogs/remote-operations.yaml",
  "openspec/verification/policy.md",
  "openspec/verification/acceptance-index.txt",
  "openspec/verification/acceptance-cases.yaml",
  "scripts/check-sdd.rb",
  "scripts/check-sdd.sh",
  "scripts/check-json.py",
  "scripts/sdd-protected-set.rb",
  "scripts/relock-baseline.rb",
  "scripts/guard-selftest.rb"
].freeze

# Expands the protected patterns against a repository root and returns
# repo-relative paths, unique and sorted — the exact set the file manifest
# must contain, no more and no less.
def sdd_protected_files(root)
  root = Pathname.new(root)
  SDD_PROTECTED_PATTERNS.flat_map { |pattern| Dir.glob(root.join(pattern)) }
                        .select { |path| File.file?(path) }
                        .map { |path| Pathname.new(path).relative_path_from(root).to_s }
                        .uniq
                        .sort
end
