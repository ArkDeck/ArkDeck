#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "date"
require "json"
require "open3"
require "pathname"
require "tempfile"
require "timeout"
require "yaml"

require_relative "sdd-protected-set"

ROOT = Pathname.new(__dir__).parent.expand_path
errors = []
RFC3339_DATE_TIME = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})\z/
CANONICAL_GIT_OID = /\A(?:[a-f0-9]{40}|[a-f0-9]{64})\z/
PRE_ARCHIVE_INVARIANTS = %w[
  task-packet-ready-and-pins
  atomic-claim-owner-and-lease
  canonical-resource-identity
  controlled-lab-pre-dispatch-authorization
  typed-plan-to-execution-binding
  hardware-evidence-provenance
  approval-chronology
  exact-task-result-aggregate-provenance
  acceptance-and-change-verification
].freeze
PLATFORM_REVALIDATION_TRIGGERS = %w[
  implementationRevisionChanged
  releaseArtifactChanged
  osBuildChanged
  architectureChanged
  toolchainChanged
  platformProfileChanged
  platformVerificationChanged
  coreBaselineChanged
  conformanceSuiteChanged
  integrationLockChanged
].freeze
CORE_ACCEPTANCE_ID = /\AAC-[A-Z]+-[0-9]{3}-[0-9]{2}\z/
PLATFORM_ACCEPTANCE_ID = /\A[A-Z]+-M[0-9]+[A-Z]*-[A-Z0-9]+(?:-[A-Z0-9]+)*-[0-9]{3}\z/
ACCEPTANCE_EVIDENCE_CLASSES = %w[contract parserGolden platform realHardware manualReview].freeze

def acceptance_case_contract_sha256(acceptance_id, definition)
  normalized = {
    "acceptanceId" => acceptance_id,
    "testId" => definition && definition["test_id"],
    "method" => definition && definition["method"],
    "minimumEvidence" => definition && definition["minimum_evidence"],
    "hardwareCapability" => definition && definition["hardware_capability"],
    "sourceSha256" => definition && definition["source_sha256"],
    "expectedResult" => definition && definition["expected_result"]
  }
  Digest::SHA256.hexdigest(JSON.generate(normalized))
end

def port_contract_sha256(port_id, definition)
  Digest::SHA256.hexdigest(JSON.generate(
    "portId" => port_id,
    "portName" => definition && definition["name"],
    "normativeBehavior" => definition && definition["behavior"]
  ))
end

def support_cell_contract_sha256(cell)
  Digest::SHA256.hexdigest(JSON.generate(
    "cellId" => cell && cell["cellId"],
    "implementation" => cell && cell["implementation"],
    "environment" => cell && cell["environment"]
  ))
end

case_hash_self_test = {
  "test_id" => "TEST-CASE-HASH",
  "method" => "realHardwareMatrix",
  "minimum_evidence" => "realHardware",
  "hardware_capability" => "flash",
  "source_sha256" => "a" * 64,
  "expected_result" => nil
}
case_hash_baseline = acceptance_case_contract_sha256("AC-CASE-HASH-001-01", case_hash_self_test)
errors << "acceptance case contract hash ignores canonical Scenario semantics" if case_hash_baseline == acceptance_case_contract_sha256(
  "AC-CASE-HASH-001-01", case_hash_self_test.merge("source_sha256" => "b" * 64)
)
errors << "acceptance case contract hash ignores platform expected result" if case_hash_baseline == acceptance_case_contract_sha256(
  "AC-CASE-HASH-001-01", case_hash_self_test.merge("expected_result" => "different result")
)

def relative(path)
  Pathname.new(path).relative_path_from(ROOT).to_s
end

def archived_change_path?(path)
  relative(path).start_with?("openspec/changes/archive/")
end

def git_commit?(revision)
  return false unless revision.to_s.match?(CANONICAL_GIT_OID) && ROOT.join(".git").exist?

  stdout, _stderr, status = Open3.capture3("git", "-C", ROOT.to_s, "rev-parse", "--verify", "#{revision}^{commit}")
  status.success? && stdout.strip == revision
end

def git_head_revision
  return nil unless ROOT.join(".git").exist?

  stdout, _stderr, status = Open3.capture3("git", "-C", ROOT.to_s, "rev-parse", "HEAD")
  status.success? ? stdout.strip : nil
end

def git_ancestor?(ancestor, descendant)
  return false unless git_commit?(ancestor) && git_commit?(descendant)

  _stdout, _stderr, status = Open3.capture3("git", "-C", ROOT.to_s, "merge-base", "--is-ancestor", ancestor, descendant)
  status.success?
end

def git_diff_entries(base_revision, result_revision)
  stdout, _stderr, status = Open3.capture3(
    "git", "-C", ROOT.to_s, "diff", "--name-status", "--no-renames", "--diff-filter=ACDMRTUXB", base_revision, result_revision, "--"
  )
  return nil unless status.success?

  stdout.lines(chomp: true).reject(&:empty?).map do |line|
    status_code, path = line.split("\t", 2)
    { "status" => status_code, "path" => path }
  end.sort_by { |entry| entry["path"].to_s }
end

def git_diff_paths(base_revision, result_revision)
  entries = git_diff_entries(base_revision, result_revision)
  entries&.map { |entry| entry["path"] }&.sort
end

def git_file_sha256(revision, path)
  return nil unless git_commit?(revision)

  stdout, _stderr, status = Open3.capture3("git", "-C", ROOT.to_s, "show", "#{revision}:#{path}")
  status.success? ? Digest::SHA256.hexdigest(stdout.b) : nil
end

def git_file_content(revision, path)
  return nil unless git_commit?(revision)

  stdout, _stderr, status = Open3.capture3("git", "-C", ROOT.to_s, "show", "#{revision}:#{path}")
  status.success? ? stdout : nil
end

def git_tree_entry_identity(revision, path)
  return nil unless git_commit?(revision) && !path.to_s.empty?

  stdout, _stderr, status = Open3.capture3(
    "git", "-C", ROOT.to_s, "ls-tree", "-z", revision, "--", ":(literal)#{path}"
  )
  return nil unless status.success?

  records = stdout.b.split("\0".b).reject(&:empty?)
  return nil if records.empty?
  return :invalid unless records.length == 1

  metadata, raw_path = records.first.split("\t".b, 2)
  mode, type, object_id = metadata.to_s.split(" ", 3)
  return :invalid unless raw_path == path.to_s.b && mode && type && object_id

  [mode, type, object_id]
end

def validate_task_result_aggregate(errors:, subject:, base_revision:, result_revision:, runs:, provenance_files:)
  valid = true
  unless git_commit?(base_revision) && git_commit?(result_revision) && git_ancestor?(base_revision, result_revision)
    errors << "#{subject} aggregate base/result is not a canonical ancestor pair"
    return false
  end
  if runs.empty?
    errors << "#{subject} aggregate has no exact bound done runs"
    return false
  end

  contributions = Hash.new { |hash, key| hash[key] = [] }
  runs.each do |run|
    unless run["baseRevision"] == base_revision && git_commit?(run["resultRevision"]) &&
           git_ancestor?(base_revision, run["resultRevision"]) && git_ancestor?(run["resultRevision"], result_revision)
      errors << "#{subject} run #{run['runId']} is not rooted at the exact aggregate base/result lineage"
      valid = false
      next
    end

    entries = git_diff_entries(base_revision, run["resultRevision"])
    unless entries && entries.map { |entry| entry["path"] }.sort == Array(run["modifiedFiles"]).sort
      errors << "#{subject} run #{run['runId']} does not contribute its exact approved Git diff"
      valid = false
      next
    end
    entries.each do |entry|
      identity = git_tree_entry_identity(run["resultRevision"], entry["path"])
      if identity == :invalid
        errors << "#{subject} run #{run['runId']} has an ambiguous Git tree path #{entry['path']}"
        valid = false
      else
        contributions[entry["path"]] << (identity || [:absent])
      end
    end
  end

  conflicting_paths = contributions.filter_map do |path, identities|
    path if identities.uniq.length != 1
  end.sort
  unless conflicting_paths.empty?
    errors << "#{subject} bound runs have conflicting final Git tree identities: #{conflicting_paths.join(', ')}"
    valid = false
  end

  aggregate_entries = git_diff_entries(base_revision, result_revision)
  unless aggregate_entries
    errors << "#{subject} aggregate Git diff cannot be read"
    return false
  end
  aggregate_by_path = aggregate_entries.to_h { |entry| [entry["path"], entry] }
  unless aggregate_by_path.length == aggregate_entries.length
    errors << "#{subject} aggregate Git diff contains duplicate paths"
    valid = false
  end

  owned_paths = contributions.keys.sort
  aggregate_paths = aggregate_by_path.keys.sort
  missing_owned_paths = owned_paths - aggregate_paths
  unless missing_owned_paths.empty?
    errors << "#{subject} drops approved Task result paths: #{missing_owned_paths.join(', ')}"
    valid = false
  end
  owned_paths.each do |path|
    next unless aggregate_by_path.key?(path) && contributions[path].uniq.length == 1

    final_identity = git_tree_entry_identity(result_revision, path)
    expected_identity = contributions[path].first == [:absent] ? nil : contributions[path].first
    unless final_identity == expected_identity
      errors << "#{subject} final Git tree overrides approved Task result path #{path}"
      valid = false
    end
  end

  unowned_paths = aggregate_paths - owned_paths
  unknown_paths = unowned_paths - provenance_files.keys
  unless unknown_paths.empty?
    errors << "#{subject} contains paths not owned by any approved Task run or exact lifecycle provenance: #{unknown_paths.join(', ')}"
    valid = false
  end
  (unowned_paths & provenance_files.keys).each do |path|
    identity = git_tree_entry_identity(result_revision, path)
    expected_sha256 = provenance_files[path]
    exact_regular_blob = identity.is_a?(Array) && identity[0] == "100644" && identity[1] == "blob" &&
                         git_file_sha256(result_revision, path) == expected_sha256
    unless exact_regular_blob
      errors << "#{subject} lifecycle provenance bytes or Git mode drift at #{path}"
      valid = false
    end
  end

  valid
end

def git_tree_paths(revision, prefix)
  return nil unless git_commit?(revision)

  stdout, _stderr, status = Open3.capture3(
    "git", "-C", ROOT.to_s, "ls-tree", "-r", "--name-only", revision, "--", prefix
  )
  status.success? ? stdout.lines(chomp: true).reject(&:empty?).sort : nil
end

def git_path_add_commits(ancestor_revision, descendant_revision, path)
  return nil unless git_commit?(ancestor_revision) && git_commit?(descendant_revision) && git_ancestor?(ancestor_revision, descendant_revision)

  stdout, _stderr, status = Open3.capture3(
    "git", "-C", ROOT.to_s, "log", "--format=%H", "--diff-filter=A", "--reverse",
    "#{ancestor_revision}..#{descendant_revision}", "--", path
  )
  status.success? ? stdout.lines(chomp: true).reject(&:empty?) : nil
end

def platform_context_for_task(revision, task)
  return nil unless task && git_commit?(revision)

  lock_source = git_file_content(revision, "openspec/platforms/PLATFORM-PROFILES.lock.yaml")
  return nil unless lock_source

  lock = YAML.safe_load(lock_source, permitted_classes: [Date, Time], aliases: false) || {}
  entry = Array(lock["profiles"]).find do |candidate|
    candidate["id"] == task.dig("platformProfile", "id") &&
      candidate["version"] == task.dig("platformProfile", "version") &&
      candidate["platform"] == task["platform"] &&
      candidate["profile_sha256"] == task.dig("platformProfile", "sha256")
  end
  return nil unless entry && git_file_sha256(revision, entry["profile_path"].to_s) == entry["profile_sha256"]

  case_source = git_file_content(revision, entry["case_manifest_path"].to_s)
  return nil unless case_source && Digest::SHA256.hexdigest(case_source.b) == entry["case_manifest_sha256"]

  case_document = YAML.safe_load(case_source, permitted_classes: [Date, Time], aliases: false) || {}
  return nil unless case_document["platform"] == task["platform"]

  { "lock" => lock, "entry" => entry, "caseDocument" => case_document }
rescue Psych::Exception
  nil
end

def canonical_markdown_block(text, heading_pattern, following_heading_pattern)
  start_match = text.match(heading_pattern)
  return nil unless start_match

  tail = text[start_match.begin(0)..]
  following_heading = tail.match(following_heading_pattern, start_match[0].length)
  block = following_heading ? tail[0...following_heading.begin(0)] : tail
  "#{block.rstrip}\n"
end

def canonical_non_requirement_content(text)
  remainder = text.dup
  outside = +""
  loop do
    start_match = remainder.match(/^### Requirement: REQ-[A-Z0-9-]+\b.*$/)
    unless start_match
      outside << remainder
      break
    end
    outside << remainder[0...start_match.begin(0)]
    tail = remainder[start_match.begin(0)..]
    following_heading = tail.match(/^\#{1,3} /, start_match[0].length)
    break unless following_heading

    remainder = tail[following_heading.begin(0)..]
  end
  normalized_lines = outside.lines.map(&:rstrip).reject(&:empty?)
  normalized_lines.empty? ? "" : "#{normalized_lines.join("\n")}\n"
end

spec_shell_self_test_a = "# Capability\nPreamble\n\n### Requirement: REQ-X-001 One\nBody A\n#### Scenario: AC-X-001-01 One\n- THEN A\n"
spec_shell_self_test_b = "# Capability\nPreamble\n\n### Requirement: REQ-X-001 One\nBody B\n#### Scenario: AC-X-001-01 One\n- THEN B\n"
spec_shell_self_test_c = spec_shell_self_test_b.sub("Preamble", "Changed preamble")
errors << "spec non-Requirement shell guard self-test failed for a Requirement-only change" unless canonical_non_requirement_content(spec_shell_self_test_a) == canonical_non_requirement_content(spec_shell_self_test_b)
errors << "spec non-Requirement shell guard self-test failed for a preamble change" if canonical_non_requirement_content(spec_shell_self_test_a) == canonical_non_requirement_content(spec_shell_self_test_c)

def behavior_target_spec_path(delta_path)
  match = delta_path.to_s.match(%r{(?:\A|/)specs/(.+/spec\.md)\z})
  match && "openspec/specs/#{match[1]}"
end

def normative_spec_snapshot(sources:, errors:, subject:)
  requirement_records = {}
  requirement_acceptance = {}
  acceptance_owner = {}
  files = {}
  sources.each do |source|
    path = source.fetch("path")
    text = source.fetch("text")
    files[path] = {
      "sha256" => Digest::SHA256.hexdigest(text.b),
      "non_requirement_sha256" => Digest::SHA256.hexdigest(canonical_non_requirement_content(text))
    }
    requirement_ids = text.scan(/^### Requirement: (REQ-[A-Z0-9-]+)\b/).flatten
    requirement_ids.each do |requirement_id|
      if requirement_records.key?(requirement_id)
        errors << "#{subject} contains duplicate Requirement #{requirement_id}"
        next
      end
      block = canonical_markdown_block(
        text,
        /^### Requirement: #{Regexp.escape(requirement_id)}\b.*$/,
        /^\#{1,3} /
      )
      if block.nil?
        errors << "#{subject} cannot canonicalize Requirement #{requirement_id}"
        next
      end
      acceptance_ids = block.scan(/^#### Scenario: (AC-[A-Z0-9-]+)\b/).flatten
      errors << "#{subject} Requirement #{requirement_id} has no Scenario" if acceptance_ids.empty?
      requirement_records[requirement_id] = {
        "path" => path,
        "block_sha256" => Digest::SHA256.hexdigest(block),
        "acceptance" => acceptance_ids
      }
      requirement_acceptance[requirement_id] = acceptance_ids
      acceptance_ids.each do |acceptance_id|
        if (prior_owner = acceptance_owner[acceptance_id])
          errors << "#{subject} assigns Acceptance #{acceptance_id} to both #{prior_owner} and #{requirement_id}"
        else
          acceptance_owner[acceptance_id] = requirement_id
        end
      end
    end
  end
  {
    "requirements" => requirement_records,
    "requirement_acceptance" => requirement_acceptance,
    "acceptance_owner" => acceptance_owner,
    "files" => files
  }
end

def git_normative_spec_snapshot(revision:, errors:, subject:)
  paths = git_tree_paths(revision, "openspec/specs")
  if paths.nil?
    errors << "#{subject} cannot read the Git specs tree at #{revision}"
    return nil
  end
  spec_paths = paths.select { |path| path.match?(%r{\Aopenspec/specs/.+/spec\.md\z}) }
  sources = spec_paths.filter_map do |path|
    text = git_file_content(revision, path)
    if text.nil?
      errors << "#{subject} cannot read #{path} at #{revision}"
      nil
    else
      { "path" => path, "text" => text }
    end
  end
  normative_spec_snapshot(sources: sources, errors: errors, subject: subject)
end

def apply_behavior_overlay_to_snapshot(baseline_snapshot, overlay)
  expected = baseline_snapshot.fetch("requirements").transform_values(&:dup)
  overlay.fetch("records").each do |requirement_id, record|
    next unless %w[added modified].include?(record["operation"])

    expected[requirement_id] = {
      "path" => record["target_path"],
      "block_sha256" => record["block_sha256"],
      "acceptance" => record["scenarios"]
    }
  end
  expected
end

def walk_hash_entries(value, &block)
  case value
  when Hash
    yield(value) if value.key?("path") && value.key?("sha256")
    value.each_value { |child| walk_hash_entries(child, &block) }
  when Array
    value.each { |child| walk_hash_entries(child, &block) }
  end
end

def markdown_frontmatter(path)
  text = Pathname.new(path).read
  source = text[/\A---\s*\n(.*?)\n---\s*\n/m, 1]
  source ? (YAML.safe_load(source, aliases: false) || {}) : {}
end

def yaml_ambiguities(source)
  findings = []
  stream = Psych.parse_stream(source)
  findings << "$yaml: exactly one YAML document is required" unless stream.children.length == 1
  visit = lambda do |node, location|
    if node.is_a?(Psych::Nodes::Alias)
      findings << "#{location}: YAML aliases are forbidden"
      next
    end
    findings << "#{location}: YAML anchors are forbidden" if node.respond_to?(:anchor) && !node.anchor.to_s.empty?
    case node
    when Psych::Nodes::Stream
      node.children.each_with_index { |child, index| visit.call(child, "#{location}/document[#{index}]") }
    when Psych::Nodes::Document
      visit.call(node.root, "#{location}/root") if node.root
    when Psych::Nodes::Mapping
      seen = {}
      node.children.each_slice(2).with_index do |(key, value), index|
        if !key.is_a?(Psych::Nodes::Scalar)
          findings << "#{location}/key[#{index}]: mapping keys must be scalars"
        else
          key_name = key.value.to_s
          findings << "#{location}/#{key_name}: duplicate YAML mapping key" if seen[key_name]
          findings << "#{location}/#{key_name}: YAML merge keys are forbidden" if key_name == "<<"
          seen[key_name] = true
        end
        visit.call(key, "#{location}/key[#{index}]")
        visit.call(value, "#{location}/value[#{index}]") if value
      end
    when Psych::Nodes::Sequence
      node.children.each_with_index { |child, index| visit.call(child, "#{location}[#{index}]") }
    end
  end
  visit.call(stream, "$yaml")
  findings
end

errors << "YAML ambiguity guard self-test failed for a nested duplicate key" if yaml_ambiguities("outer:\n  key: one\n  key: two\n").empty?
errors << "YAML ambiguity guard self-test failed for an alias" if yaml_ambiguities("one: &value x\ntwo: *value\n").empty?
errors << "YAML ambiguity guard self-test failed for a multi-document stream" if yaml_ambiguities("status: review\n---\nstatus: accepted\n").empty?

def validate_platform_revalidation(errors:, subject:, matrix:, declared_platforms:, current_delivery_platforms:)
  matrix = {} unless matrix.is_a?(Hash)
  actual_platforms = matrix.keys.map(&:to_s).sort
  errors << "#{subject} lacks an exact target-platform revalidation matrix" unless actual_platforms == declared_platforms

  matrix.each do |platform, disposition|
    valid = disposition.is_a?(Hash) &&
            %w[reverifyRequired nonConformant deferred].include?(disposition["disposition"]) &&
            !disposition["owner"].to_s.empty? &&
            !disposition["milestone"].to_s.empty?
    errors << "#{subject} has invalid revalidation disposition for #{platform}" unless valid
    if current_delivery_platforms.include?(platform.to_s) && disposition.is_a?(Hash) && disposition["disposition"] == "deferred"
      errors << "#{subject} defers current delivery platform #{platform}"
    end
  end
end

def validate_platform_lifecycle(errors:, subject:, lock:, declared_platforms:)
  current = Array(lock["current_delivery_platforms"]).map(&:to_s)
  not_started = Array(lock["not_started_platforms"]).map(&:to_s)
  errors << "#{subject} has duplicate current-delivery platforms" unless current.uniq.length == current.length
  errors << "#{subject} has duplicate not-started platforms" unless not_started.uniq.length == not_started.length
  errors << "#{subject} platform lifecycle sets overlap" unless (current & not_started).empty?
  errors << "#{subject} platform lifecycle does not exactly cover declared targets" unless (current + not_started).sort == declared_platforms

  profiles = Array(lock["profiles"])
  profile_platforms = profiles.map { |entry| entry["platform"].to_s }
  errors << "#{subject} profile set differs from declared targets" unless profile_platforms.sort == declared_platforms
  not_started.each do |platform|
    entry = profiles.find { |candidate| candidate["platform"].to_s == platform }
    errors << "#{subject} not-started platform #{platform} is not in notStarted conformance state" unless entry && entry["conformance_status"] == "notStarted"
  end
end

def validate_platform_transition(errors:, subject:, prior:, current:)
  prior_entries = Array(prior["profiles"]).to_h { |entry| [entry["platform"], entry] }
  Array(current["profiles"]).each do |entry|
    previous = prior_entries[entry["platform"]]
    next unless previous

    if %w[verified needsReverification].include?(previous["conformance_status"]) && entry["conformance_status"] == "notStarted"
      errors << "#{subject} illegally resets #{entry['platform']} conformance history to notStarted"
    end
    if %w[needsReverification nonConformant].include?(entry["conformance_status"]) &&
       %w[verified needsReverification].include?(previous["conformance_status"]) &&
       entry["last_verified"] != previous["last_verified"]
      errors << "#{subject} #{entry['platform']} #{entry['conformance_status']} erases or rewrites prior verified pins/evidence"
    end
  end
end

def change_supersession_cycles(links)
  cycles = []
  links.each_key do |start|
    order = []
    positions = {}
    cursor = start
    while cursor && links.key?(cursor)
      if positions.key?(cursor)
        cycle = order[positions[cursor]..].sort
        cycles << cycle unless cycles.include?(cycle)
        break
      end
      positions[cursor] = order.length
      order << cursor
      cursor = links[cursor]
    end
  end
  cycles
end

def claim_precedes_successor?(claimed_at:, successor_approved_at:)
  claimed_at < successor_approved_at
end

def predecessor_claim_closed_before_successor?(claimed_at:, terminal_at:, successor_approved_at:)
  claim_precedes_successor?(claimed_at: claimed_at, successor_approved_at: successor_approved_at) &&
    terminal_at && terminal_at < successor_approved_at
end

lineage_test_time = DateTime.iso8601("2026-01-01T00:00:01Z")
errors << "Change lineage cycle guard self-test failed" if change_supersession_cycles("A" => "B", "B" => "A").empty?
errors << "Change lineage acyclic guard self-test failed" unless change_supersession_cycles("B" => "A", "C" => "B").empty?
errors << "post-supersession claim guard self-test failed" if claim_precedes_successor?(claimed_at: lineage_test_time, successor_approved_at: lineage_test_time)
errors << "active predecessor claim guard self-test failed" if predecessor_claim_closed_before_successor?(
  claimed_at: lineage_test_time - Rational(2, 86_400), terminal_at: nil, successor_approved_at: lineage_test_time
)
errors << "closed predecessor claim guard self-test failed" unless predecessor_claim_closed_before_successor?(
  claimed_at: lineage_test_time - Rational(2, 86_400),
  terminal_at: lineage_test_time - Rational(1, 86_400),
  successor_approved_at: lineage_test_time
)

def required_change_artifact_paths(change_root, proposal)
  paths = %w[proposal.md scope.yaml design.md verification.md review.md ready-review.md acceptance-cases.yaml]
          .map { |name| change_root.join(name) }
  paths << change_root.join("spec-impact.md") if proposal["schema"] == "arkdeck-platform"
  paths
end

def expected_change_input_paths(change_root)
  proposal_path = change_root.join("proposal.md")
  proposal = proposal_path.file? ? markdown_frontmatter(proposal_path) : {}
  paths = required_change_artifact_paths(change_root, proposal)
  if proposal["schema"] == "arkdeck-behavior"
    paths += Dir.glob(change_root.join("specs/**/*.md").to_s).map { |entry| Pathname.new(entry) }
  end
  paths.map { |entry| relative(entry) }.uniq.sort
end

def build_behavior_overlay(delta_sources:, baseline_requirement_acceptance:, baseline_acceptance_owner:, errors:, subject:, baseline_requirement_paths: {})
  records = {}
  delta_sources.each do |source|
    section = nil
    current_requirement = nil
    fenced = false
    html_comment = false
    seen_sections = {}
    source.fetch("text").each_line.with_index(1) do |line, line_number|
      if line.match?(/\A(?:```|~~~)/)
        fenced = !fenced
        next
      end
      next if fenced
      if html_comment
        html_comment = false if line.include?("-->")
        next
      elsif line.include?("<!--")
        html_comment = true unless line.include?("-->")
        next
      end

      if (match = line.match(/\A## (ADDED|MODIFIED|REMOVED|RENAMED) Requirements\s*\z/))
        section = match[1].downcase
        errors << "#{subject} repeats the #{match[1]} Requirements section in #{source.fetch('path')}" if seen_sections[section]
        seen_sections[section] = true
        current_requirement = nil
        next
      elsif line.match?(/\A## /)
        section = nil
        current_requirement = nil
        next
      end

      if (match = line.match(/\A### Requirement: (REQ-[A-Z0-9-]+)\b/))
        current_requirement = nil
        requirement_id = match[1]
        if section == "renamed"
          errors << "#{subject} uses unsupported V1 RENAMED Requirement #{requirement_id}; create a complete MODIFIED replacement with stable IDs"
          next
        elsif section == "removed"
          errors << "#{subject} uses unsupported V1 REMOVED Requirement #{requirement_id}; removal requires a future tombstone/migration contract"
          next
        elsif !%w[added modified].include?(section)
          errors << "#{subject} has Requirement #{requirement_id} outside an ADDED/MODIFIED section"
          next
        end

        if records.key?(requirement_id)
          errors << "#{subject} declares #{requirement_id} more than once"
          next
        end
        records[requirement_id] = {
          "operation" => section,
          "scenarios" => [],
          "path" => source.fetch("path"),
          "target_path" => behavior_target_spec_path(source.fetch("path")),
          "line" => line_number,
          "block_sha256" => Digest::SHA256.hexdigest(
            canonical_markdown_block(
              source.fetch("text"),
              /^### Requirement: #{Regexp.escape(requirement_id)}\b.*$/,
              /^\#{1,3} /
            ).to_s
          )
        }
        errors << "#{subject} delta #{source.fetch('path')} does not map to openspec/specs/<capability>/spec.md" if records[requirement_id]["target_path"].nil?
        current_requirement = requirement_id
        next
      end

      match = line.match(/\A#### Scenario: (AC-[A-Z0-9-]+)\b/)
      unless match
        if %w[removed renamed].include?(section) && !line.strip.empty?
          errors << "#{subject} has unsupported V1 #{section.upcase} content at #{source.fetch('path')}:#{line_number}"
        end
        next
      end

      acceptance_id = match[1]
      if current_requirement.nil?
        errors << "#{subject} has Scenario #{acceptance_id} outside an ADDED/MODIFIED Requirement"
        next
      end
      record = records.fetch(current_requirement)
      if record["operation"] == "removed"
        errors << "#{subject} removed Requirement #{current_requirement} must be a tombstone without Scenario blocks"
        next
      end
      if record["scenarios"].include?(acceptance_id)
        errors << "#{subject} declares Scenario #{acceptance_id} more than once in #{current_requirement}"
        next
      end
      record["scenarios"] << acceptance_id
      scenario_block = canonical_markdown_block(
        source.fetch("text"),
        /^#### Scenario: #{Regexp.escape(acceptance_id)}\b.*$/,
        /^\#{1,4} /
      )
      record["scenario_metadata"] ||= {}
      record["scenario_metadata"][acceptance_id] = {
        "path" => source.fetch("path"),
        "anchor" => acceptance_id,
        "block_sha256" => Digest::SHA256.hexdigest(scenario_block.to_s)
      }
    end
    errors << "#{subject} has an unclosed Markdown fence in #{source.fetch('path')}" if fenced
  end

  effective_requirements = baseline_requirement_acceptance.transform_values(&:dup)
  touched_requirements = []
  touched_acceptance = []
  scenario_sources = {}

  records.each do |requirement_id, record|
    operation = record.fetch("operation")
    scenarios = record.fetch("scenarios")
    touched_requirements << requirement_id
    case operation
    when "added"
      if baseline_requirement_acceptance.key?(requirement_id)
        errors << "#{subject} ADDED Requirement #{requirement_id} already exists in its baseline"
      end
      unless baseline_requirement_paths.values.include?(record["target_path"])
        errors << "#{subject} ADDED Requirement #{requirement_id} targets a new spec file; V1 requires adding to an existing capability spec so full-file archive equality is deterministic"
      end
      errors << "#{subject} ADDED Requirement #{requirement_id} has no complete Scenario set" if scenarios.empty?
      scenarios.each do |acceptance_id|
        if baseline_acceptance_owner.key?(acceptance_id)
          errors << "#{subject} ADDED Requirement #{requirement_id} reuses baseline Acceptance #{acceptance_id}"
        end
        touched_acceptance << acceptance_id
        scenario_sources[acceptance_id] = record.fetch("scenario_metadata").fetch(acceptance_id)
      end
      effective_requirements[requirement_id] = scenarios.dup unless baseline_requirement_acceptance.key?(requirement_id)
    when "modified"
      baseline_scenarios = baseline_requirement_acceptance[requirement_id]
      if baseline_scenarios.nil?
        errors << "#{subject} MODIFIED Requirement #{requirement_id} does not exist in its baseline"
        next
      end
      baseline_path = baseline_requirement_paths[requirement_id]
      if baseline_path && record["target_path"] != baseline_path
        errors << "#{subject} MODIFIED Requirement #{requirement_id} targets #{record['target_path']} instead of baseline path #{baseline_path}"
      end
      errors << "#{subject} MODIFIED Requirement #{requirement_id} has no complete replacement Scenario set" if scenarios.empty?
      missing_baseline_scenarios = baseline_scenarios - scenarios
      unless missing_baseline_scenarios.empty?
        errors << "#{subject} MODIFIED Requirement #{requirement_id} removes Acceptance #{missing_baseline_scenarios.join(', ')}; V1 requires preserving all old AC IDs"
      end
      scenarios.each do |acceptance_id|
        baseline_owner = baseline_acceptance_owner[acceptance_id]
        if baseline_owner && baseline_owner != requirement_id
          errors << "#{subject} MODIFIED Requirement #{requirement_id} moves/reuses Acceptance #{acceptance_id} from #{baseline_owner}"
        end
        scenario_sources[acceptance_id] = record.fetch("scenario_metadata").fetch(acceptance_id)
      end
      touched_acceptance.concat(baseline_scenarios | scenarios)
      effective_requirements[requirement_id] = scenarios.dup
    end
  end

  effective_acceptance_owner = {}
  effective_requirements.each do |requirement_id, acceptance_ids|
    acceptance_ids.each do |acceptance_id|
      prior_owner = effective_acceptance_owner[acceptance_id]
      if prior_owner && prior_owner != requirement_id
        errors << "#{subject} effective overlay assigns Acceptance #{acceptance_id} to both #{prior_owner} and #{requirement_id}"
      else
        effective_acceptance_owner[acceptance_id] = requirement_id
      end
    end
  end

  errors << "#{subject} has no ADDED/MODIFIED/REMOVED Requirement" if records.empty?
  {
    "records" => records,
    "effective_requirements" => effective_requirements.keys.sort,
    "effective_acceptance" => effective_acceptance_owner.keys.sort,
    "reference_requirements" => effective_requirements.keys.sort,
    "reference_acceptance" => effective_acceptance_owner.keys.sort,
    "touched_requirements" => touched_requirements.uniq.sort,
    "touched_acceptance" => touched_acceptance.uniq.sort,
    "scenario_sources" => scenario_sources
  }
end

overlay_self_test_errors = []
overlay_self_test = build_behavior_overlay(
  delta_sources: [{
    "path" => "openspec/changes/chg-self/specs/capability/spec.md",
    "text" => <<~MARKDOWN
      ## ADDED Requirements
      ### Requirement: REQ-NEW-001 New
      #### Scenario: AC-NEW-001-01 New
      ## MODIFIED Requirements
      ### Requirement: REQ-OLD-001 Updated
      #### Scenario: AC-OLD-001-01 Kept
      #### Scenario: AC-OLD-001-02 Kept too
      #### Scenario: AC-OLD-001-03 Added
    MARKDOWN
  }],
  baseline_requirement_acceptance: {
    "REQ-OLD-001" => %w[AC-OLD-001-01 AC-OLD-001-02]
  },
  baseline_acceptance_owner: {
    "AC-OLD-001-01" => "REQ-OLD-001",
    "AC-OLD-001-02" => "REQ-OLD-001"
  },
  baseline_requirement_paths: { "REQ-OLD-001" => "openspec/specs/capability/spec.md" },
  errors: overlay_self_test_errors,
  subject: "behavior overlay self-test"
)
overlay_self_test_valid = overlay_self_test_errors.empty? &&
                          overlay_self_test["effective_requirements"] == %w[REQ-NEW-001 REQ-OLD-001] &&
                          overlay_self_test["effective_acceptance"] == %w[AC-NEW-001-01 AC-OLD-001-01 AC-OLD-001-02 AC-OLD-001-03]
errors << "behavior baseline+delta overlay guard self-test failed: #{overlay_self_test_errors.join('; ')}" unless overlay_self_test_valid

overlay_fail_closed_errors = []
build_behavior_overlay(
  delta_sources: [{
    "path" => "openspec/changes/chg-self/specs/capability/spec.md",
    "text" => <<~MARKDOWN
      ## MODIFIED Requirements
      ### Requirement: REQ-OLD-001 Incomplete
      #### Scenario: AC-OLD-001-01 Only one old AC
      ## REMOVED Requirements
      ### Requirement: REQ-GONE-001 Unsupported
      ## CHANGED Requirements
      ### Requirement: REQ-UNKNOWN-001 Ambiguous
      ## RENAMED Requirements
      - FROM: Old title
      - TO: New title
    MARKDOWN
  }],
  baseline_requirement_acceptance: {
    "REQ-OLD-001" => %w[AC-OLD-001-01 AC-OLD-001-02],
    "REQ-GONE-001" => %w[AC-GONE-001-01]
  },
  baseline_acceptance_owner: {
    "AC-OLD-001-01" => "REQ-OLD-001",
    "AC-OLD-001-02" => "REQ-OLD-001",
    "AC-GONE-001-01" => "REQ-GONE-001"
  },
  baseline_requirement_paths: {
    "REQ-OLD-001" => "openspec/specs/capability/spec.md",
    "REQ-GONE-001" => "openspec/specs/capability/spec.md"
  },
  errors: overlay_fail_closed_errors,
  subject: "behavior fail-closed self-test"
)
unless overlay_fail_closed_errors.any? { |item| item.include?("unsupported V1 REMOVED") } &&
       overlay_fail_closed_errors.any? { |item| item.include?("requires preserving all old AC IDs") } &&
       overlay_fail_closed_errors.any? { |item| item.include?("outside an ADDED/MODIFIED section") } &&
       overlay_fail_closed_errors.any? { |item| item.include?("unsupported V1 RENAMED content") }
  errors << "behavior unsupported/removal/ambiguous-section guard self-test failed"
end

def plan_executables(plan)
  steps = Array(plan && plan["steps"])
  steps + steps.flat_map { |step| Array(step["compensationDescriptors"]) }
end

def runtime_capability_for_step(record)
  return nil unless record["disposition"] == "executed"

  case record["effect"]
  when "readOnly"
    record["bindingRequirement"] == "confirmedDevice" ? "realDeviceRead" : nil
  when "deviceMutation"
    "realDeviceMutation"
  when "destructive"
    "destructiveDeviceMutation"
  end
end

errors << "runtime-capability guard self-test failed for destructive execution" unless runtime_capability_for_step(
  "disposition" => "executed", "effect" => "destructive", "bindingRequirement" => "confirmedDevice"
) == "destructiveDeviceMutation"
errors << "runtime-capability guard self-test failed for skipped destructive plan" unless runtime_capability_for_step(
  "disposition" => "skipped", "effect" => "destructive", "bindingRequirement" => "confirmedDevice"
).nil?

def externally_verified?(approval_path, subject, approval, verifiers)
  Array(verifiers).any? do |entry|
    next false unless Array(entry["mechanisms"]).include?(approval["mechanism"])
    next false unless Array(entry["subject_types"]).include?(approval["subjectType"])
    next false if approval["issuer"].is_a?(Hash) && approval.dig("issuer", "id") != entry["id"]

    executable = Pathname.new(entry["executable_path"].to_s)
    next false unless executable.absolute? && executable.file? && executable.executable?
    begin
      next false unless executable.relative_path_from(ROOT).to_s.start_with?("../")
    rescue ArgumentError
      next false
    end
    next false unless Digest::SHA256.file(executable).hexdigest == entry["sha256"]

    begin
      _stdout, _stderr, status = Timeout.timeout(15) do
        Open3.capture3(
          executable.to_s,
          "verify",
          "--attestation",
          approval_path.to_s,
          "--subject",
          subject.to_s
        )
      end
      status.success?
    rescue Timeout::Error, SystemCallError
      false
    end
  end
end

def externally_verified_content?(approval_path, subject_content, subject_name, approval, verifiers)
  return false unless approval_path && subject_content

  suffix = File.extname(subject_name.to_s)
  Tempfile.create(["arkdeck-historical-subject-", suffix]) do |file|
    file.binmode
    file.write(subject_content.b)
    file.flush
    file.chmod(0o400)
    externally_verified?(approval_path, file.path, approval, verifiers)
  end
rescue SystemCallError
  false
end

def valid_historical_approval?(source:, subject_name:, document:, approval:, approval_path:, subject_type:, subject_id:, result_revision:, verifiers:, exact_base: false)
  return false unless source && approval && approval_path

  base_valid = git_commit?(approval["baseRevision"]) && git_ancestor?(approval["baseRevision"], result_revision)
  base_valid &&= approval["baseRevision"] == result_revision if exact_base
  approval["subjectType"] == subject_type &&
    approval["subjectId"] == subject_id &&
    approval["subjectRevision"] == document["revision"] &&
    approval["subjectSha256"] == Digest::SHA256.hexdigest(source.b) &&
    approval["decision"] == "approved" && base_valid &&
    externally_verified_content?(approval_path, source, subject_name, approval, verifiers)
end

def valid_task_supersession?(run:, run_path:, original:, replacement:, replacement_path:, approvals:, approval_paths:, verifiers:)
  return false unless original && replacement && replacement_path && replacement_path.file?
  return false unless run["supersededByTaskId"] == replacement["taskId"] && replacement["taskId"] != original["taskId"]
  return false unless replacement["status"] == "ready" && replacement["revision"] == 1
  return false unless %w[changeId changeRevision platform baseRevision].all? { |field| replacement[field] == original[field] }
  return false unless (Array(original["requirementRefs"]) - Array(replacement["requirementRefs"])).empty?
  return false unless (Array(original["acceptanceRefs"]) - Array(replacement["acceptanceRefs"])).empty?
  return false unless (Array(original["allowedPaths"]) - Array(replacement["allowedPaths"])).empty?
  return false unless (Array(original["forbiddenPaths"]) - Array(replacement["forbiddenPaths"])).empty?
  return false unless (Array(original["deliverables"]) - Array(replacement["deliverables"])).empty?

  replacement_approval = approvals[replacement["approvalId"]]
  scope_approval = approvals[run["supersessionApprovalId"]]
  return false unless replacement_approval && scope_approval
  begin
    ended_at = DateTime.iso8601(run.fetch("endedAt"))
    replacement_approved_at = DateTime.iso8601(replacement_approval.fetch("approvedAt"))
    scope_approved_at = DateTime.iso8601(scope_approval.fetch("approvedAt"))
    return false unless ended_at <= replacement_approved_at && replacement_approved_at <= scope_approved_at
  rescue KeyError, Date::Error
    return false
  end
  replacement_valid = replacement_approval["subjectType"] == "taskPacket" &&
                      replacement_approval["subjectId"] == replacement["taskId"] &&
                      replacement_approval["subjectRevision"] == replacement["revision"] &&
                      replacement_approval["subjectSha256"] == Digest::SHA256.file(replacement_path).hexdigest &&
                      replacement_approval["baseRevision"] == replacement["baseRevision"] &&
                      replacement_approval["decision"] == "approved" &&
                      externally_verified?(approval_paths[replacement_approval["approvalId"]], replacement_path, replacement_approval, verifiers)
  scope_valid = scope_approval["subjectType"] == "taskSupersession" &&
                scope_approval["subjectId"] == run["runId"] &&
                scope_approval["subjectRevision"] == run["attempt"] &&
                scope_approval["subjectSha256"] == Digest::SHA256.file(run_path).hexdigest &&
                scope_approval["baseRevision"] == run["baseRevision"] &&
                scope_approval["decision"] == "approved" &&
                externally_verified?(approval_paths[scope_approval["approvalId"]], run_path, scope_approval, verifiers)
  replacement_valid && scope_valid
end

def validate_change_supersession_barrier(errors:, successor_id:, successor_record:, predecessor_id:, predecessor_record:, verifiers:)
  barrier_path = successor_record["proposal_path"].parent.join("supersession-barrier-attestation.json")
  unless barrier_path.file?
    errors << "approved successor Change #{successor_id} lacks a protected supersession barrier attestation"
    return nil
  end

  barrier = JSON.parse(barrier_path.read)
  successor_lock_path = successor_record["lock_path"]
  predecessor_lock_path = predecessor_record["lock_path"]
  predecessor_root = predecessor_record["proposal_path"].parent.expand_path
  expected_claim_paths = Dir.glob(predecessor_root.join("evidence/runs/**/claim.json")).map { |path| relative(path) }.sort
  inventory = Array(barrier["claims"])
  inventory_claim_paths = inventory.map { |entry| entry["claimPath"] }

  begin
    closed_at = DateTime.iso8601(barrier.fetch("closedAt"))
    successor_approved_at = successor_record.fetch("approved_at")
    predecessor_approved_at = predecessor_record.fetch("approved_at")
    chronology_valid = predecessor_approved_at < closed_at && closed_at < successor_approved_at
  rescue KeyError, Date::Error, NoMethodError
    closed_at = nil
    chronology_valid = false
  end

  lock_bindings_valid = predecessor_lock_path.file? && successor_lock_path.file? &&
                        barrier.dig("predecessor", "changeId") == predecessor_id &&
                        barrier.dig("predecessor", "revision") == predecessor_record.dig("proposal", "revision") &&
                        barrier.dig("predecessor", "changeLockSha256") == Digest::SHA256.file(predecessor_lock_path).hexdigest &&
                        barrier.dig("predecessor", "changeApprovalId") == predecessor_record.dig("lock", "approval_id") &&
                        barrier.dig("successor", "changeId") == successor_id &&
                        barrier.dig("successor", "revision") == successor_record.dig("proposal", "revision") &&
                        barrier.dig("successor", "changeLockSha256") == Digest::SHA256.file(successor_lock_path).hexdigest &&
                        barrier.dig("successor", "changeApprovalId") == successor_record.dig("lock", "approval_id")
  inventory_shape_valid = barrier["attestationId"] == successor_record.dig("proposal", "supersession_barrier_attestation_id") &&
                          barrier["subjectType"] == "changeSupersessionBarrier" &&
                          barrier["mechanism"] == "protectedClaimService" &&
                          barrier["ledger"].is_a?(Hash) && !barrier.dig("ledger", "ledgerId").to_s.empty? &&
                          barrier.dig("ledger", "revision").is_a?(Integer) && barrier.dig("ledger", "revision").positive? &&
                          barrier.dig("ledger", "lineageSequence").is_a?(Integer) && barrier.dig("ledger", "lineageSequence").positive? &&
                          barrier["claimCount"] == inventory.length &&
                          inventory_claim_paths == inventory_claim_paths.sort &&
                          inventory_claim_paths.uniq.length == inventory_claim_paths.length &&
                          inventory_claim_paths == expected_claim_paths
  barrier_verified = externally_verified?(barrier_path, successor_lock_path, barrier, verifiers)

  inventory_valid = inventory.all? do |entry|
    artifact_paths = %w[claimPath claimOwnerAttestationPath runPath runOwnerAttestationPath].to_h do |field|
      [field, ROOT.join(entry[field].to_s).expand_path]
    end
    contained = artifact_paths.values.all? do |path|
      path.to_s.start_with?("#{predecessor_root}#{File::SEPARATOR}") && path.file?
    end
    next false unless contained

    claim_path = artifact_paths["claimPath"]
    claim_owner_path = artifact_paths["claimOwnerAttestationPath"]
    run_path = artifact_paths["runPath"]
    run_owner_path = artifact_paths["runOwnerAttestationPath"]
    next false unless claim_path.basename.to_s == "claim.json" && claim_owner_path.basename.to_s == "claim-owner-attestation.json" &&
                      run_path.basename.to_s == "run.json" && run_owner_path.basename.to_s == "run-owner-attestation.json" &&
                      [claim_path, claim_owner_path, run_path, run_owner_path].map(&:parent).uniq.length == 1

    claim = JSON.parse(claim_path.read)
    claim_owner = JSON.parse(claim_owner_path.read)
    run = JSON.parse(run_path.read)
    run_owner = JSON.parse(run_owner_path.read)
    begin
      claimed_at = DateTime.iso8601(claim.fetch("claimedAt"))
      terminal_at = DateTime.iso8601(run.fetch("endedAt"))
      temporal = closed_at && claimed_at < terminal_at && terminal_at < closed_at &&
                 entry["claimedAt"] == claim["claimedAt"] && entry["terminalAt"] == run["endedAt"]
    rescue KeyError, Date::Error
      temporal = false
    end
    exact = entry["claimId"] == claim["claimId"] && entry["taskId"] == claim["taskId"] && entry["attempt"] == claim["attempt"] &&
            entry["claimSha256"] == Digest::SHA256.file(claim_path).hexdigest &&
            entry["claimOwnerAttestationId"] == claim_owner["attestationId"] &&
            entry["claimOwnerAttestationSha256"] == Digest::SHA256.file(claim_owner_path).hexdigest &&
            claim_owner["subjectType"] == "taskClaim" && claim_owner["claimId"] == claim["claimId"] &&
            claim_owner["claimSha256"] == entry["claimSha256"] && claim_owner["taskId"] == claim["taskId"] &&
            claim_owner["attempt"] == claim["attempt"] &&
            entry["runId"] == run["runId"] && entry["terminalStatus"] == run["status"] &&
            %w[done blocked interrupted superseded].include?(run["status"]) && run["claimId"] == claim["claimId"] &&
            run["taskId"] == claim["taskId"] && run["attempt"] == claim["attempt"] &&
            entry["runSha256"] == Digest::SHA256.file(run_path).hexdigest &&
            entry["runOwnerAttestationId"] == run_owner["attestationId"] &&
            entry["runOwnerAttestationSha256"] == Digest::SHA256.file(run_owner_path).hexdigest &&
            run_owner["subjectType"] == "taskRunLease" && run_owner["claimAttestationId"] == claim_owner["attestationId"] &&
            run_owner["claimId"] == claim["claimId"] && run_owner["runId"] == run["runId"] &&
            run_owner["runSha256"] == entry["runSha256"] && run_owner["taskId"] == run["taskId"] &&
            run_owner["attempt"] == run["attempt"] && run_owner["finalizedAt"] == run["endedAt"] &&
            claim_owner["issuer"] == barrier["issuer"] && run_owner["issuer"] == barrier["issuer"]
    owner_proofs = externally_verified?(claim_owner_path, claim_path, claim_owner, verifiers) &&
                   externally_verified?(run_owner_path, run_path, run_owner, verifiers)
    temporal && exact && owner_proofs
  end

  valid = chronology_valid && lock_bindings_valid && inventory_shape_valid && inventory_valid && barrier_verified
  errors << "approved successor Change #{successor_id} has a stale, incomplete or unverified supersession barrier" unless valid
  valid ? { "document" => barrier, "path" => barrier_path, "closed_at" => closed_at } : nil
rescue JSON::ParserError
  errors << "approved successor Change #{successor_id} has invalid supersession barrier JSON"
  nil
end

trust_policy_path = ROOT.join("openspec/governance/trust-policy.yaml")
yaml_ambiguities(trust_policy_path.read).each { |finding| errors << "ambiguous YAML #{relative(trust_policy_path)}: #{finding}" } if trust_policy_path.file?
trust_policy = if trust_policy_path.file?
                 YAML.safe_load(trust_policy_path.read, aliases: false) || {}
               else
                 {}
               end
trusted_verifiers = []
external_trust_root = nil
external_trust_root_valid = false
trust_root_location = ENV["ARKDECK_TRUST_ROOT_BUNDLE"].to_s
unless trust_root_location.empty?
  trust_root_path = Pathname.new(trust_root_location)
  begin
    outside_repository = trust_root_path.absolute? &&
                         trust_root_path.relative_path_from(ROOT).to_s.start_with?("../")
  rescue ArgumentError
    outside_repository = false
  end
  if !outside_repository || !trust_root_path.file?
    errors << "external trust-root bundle must be an existing absolute path outside the repository"
  else
    begin
      external_root_source = trust_root_path.read
      external_root_findings = yaml_ambiguities(external_root_source)
      errors.concat(external_root_findings.map { |finding| "ambiguous external trust-root YAML: #{finding}" })
      external_trust_root = external_root_findings.empty? ? (YAML.safe_load(external_root_source, aliases: false) || {}) : {}
      declared = Array(trust_policy["external_verifiers"])
      rooted = Array(external_trust_root["external_verifiers"])
      policy_hash_matches = external_trust_root["trust_policy_sha256"] == Digest::SHA256.file(trust_policy_path).hexdigest
      root_id_matches = !external_trust_root["root_id"].to_s.empty? &&
                        trust_policy["bootstrap_root_id"] == external_trust_root["root_id"]
      repository_id_present = !external_trust_root["repository_id"].to_s.empty?
      verifier_set_matches = declared == rooted && !rooted.empty?
      external_trust_root_valid = policy_hash_matches && root_id_matches && repository_id_present && verifier_set_matches
      errors << "external trust-root bundle does not bind this policy and verifier set" unless external_trust_root_valid
      trusted_verifiers = rooted if external_trust_root_valid
    rescue Psych::Exception => e
      errors << "invalid external trust-root bundle: #{e.message}"
    end
  end
end
if trust_policy["status"] == "accepted"
  errors << "accepted trust policy gate must be open" unless trust_policy["execution_gate"] == "open"
elsif trust_policy["execution_gate"] != "closed"
  errors << "unaccepted trust policy gate must be closed"
end

Dir.glob(ROOT.join("openspec/**/*.json")).sort.each do |path|
  JSON.parse(File.read(path))
rescue JSON::ParserError => e
  errors << "invalid JSON #{relative(path)}: #{e.message}"
end

versioned_schemas = Dir.glob(ROOT.join("openspec/contracts/*.schema.json")).to_h do |path|
  document = JSON.parse(File.read(path))
  [document["$id"], document]
end

Dir.glob(ROOT.join("openspec/**/*.{yaml,yml}")).sort.each do |path|
  source = File.read(path)
  yaml_ambiguities(source).each { |finding| errors << "ambiguous YAML #{relative(path)}: #{finding}" }
  YAML.safe_load(source, permitted_classes: [Date, Time], aliases: false, filename: path)
rescue Psych::Exception => e
  errors << "invalid YAML #{relative(path)}: #{e.message}"
end

Dir.glob(ROOT.join("{AGENTS.md,docs/**/*.md,openspec/**/*.md}")).sort.each do |path|
  source = File.read(path)[/\A---\s*\n(.*?)\n---\s*\n/m, 1]
  next unless source

  yaml_ambiguities(source).each { |finding| errors << "ambiguous front matter #{relative(path)}: #{finding}" }
end

Dir.glob(ROOT.join("{AGENTS.md,docs/**/*.md,openspec/**/*.md}")).sort.each do |path|
  fence_count = File.readlines(path).count { |line| line.start_with?("```") }
  errors << "unbalanced Markdown fence #{relative(path)}" if fence_count.odd?
end

requirements = Hash.new { |hash, key| hash[key] = [] }
acceptance = Hash.new { |hash, key| hash[key] = [] }
baseline_requirement_acceptance = {}
baseline_acceptance_owner = {}
baseline_requirement_paths = {}

Dir.glob(ROOT.join("openspec/specs/**/spec.md")).sort.each do |path|
  text = File.read(path)
  text.scan(/^### Requirement: (REQ-[A-Z0-9-]+)\b/) do |match|
    requirements[match.first] << relative(path)
  end
  text.scan(/^#### Scenario: (AC-[A-Z0-9-]+)\b/) do |match|
    acceptance[match.first] << relative(path)
  end

  blocks = text.split(/^### Requirement: /).drop(1)
  blocks.each do |block|
    req_id = block[/\A(REQ-[A-Z0-9-]+)/, 1]
    next unless req_id

    scenario_ids = block.scan(/^#### Scenario: (AC-[A-Z0-9-]+)\b/).flatten
    baseline_requirement_acceptance[req_id] = scenario_ids
    baseline_requirement_paths[req_id] = relative(path)
    scenario_ids.each do |acceptance_id|
      prior_owner = baseline_acceptance_owner[acceptance_id]
      errors << "Acceptance #{acceptance_id} belongs to both #{prior_owner} and #{req_id}" if prior_owner && prior_owner != req_id
      baseline_acceptance_owner[acceptance_id] = req_id
    end
    if scenario_ids.empty?
      errors << "#{req_id} has no Scenario in #{relative(path)}"
    end
  end
end

requirements.each do |id, paths|
  errors << "duplicate Requirement #{id}: #{paths.join(', ')}" if paths.length > 1
end
acceptance.each do |id, paths|
  errors << "duplicate Acceptance #{id}: #{paths.join(', ')}" if paths.length > 1
end

constitution_text = ROOT.join("openspec/constitution.md").read
policies = constitution_text.scan(/^## (POL-[A-Z0-9-]+)\b/).flatten.to_h { |id| [id, true] }
ports_text = ROOT.join("openspec/architecture/platform-ports.md").read
ports = ports_text.scan(/`(PORT-[A-Z0-9-]+)`/).flatten.to_h { |id| [id, true] }
port_names = ports_text.scan(/^\| `PORT-[A-Z0-9-]+` \| `([A-Za-z][A-Za-z0-9]+)` \|/).flatten
port_contract_definitions = {}
ports_text.each_line do |line|
  match = line.match(/^\| `(PORT-[A-Z0-9-]+)` \| `([A-Za-z][A-Za-z0-9]+)` \| (.+) \|\s*$/)
  next unless match

  port_contract_definitions[match[1]] = { "name" => match[2], "behavior" => match[3] }
end
errors << "platform Port contract has duplicate names" unless port_names.uniq.length == port_names.length
errors << "platform Port definition parser differs from the Port ID set" unless port_contract_definitions.keys.sort == ports.keys.sort
platform_acceptance = {}
approved_hardware = {}
verified_hardware = {}

index_path = ROOT.join("openspec/verification/acceptance-index.txt")
if index_path.exist?
  indexed = index_path.readlines(chomp: true).reject { |line| line.empty? || line.start_with?("#") }
  actual = acceptance.keys.sort
  errors << "acceptance-index.txt is not sorted" unless indexed == indexed.sort
  missing = actual - indexed
  extra = indexed - actual
  errors << "acceptance index missing: #{missing.join(', ')}" unless missing.empty?
  errors << "acceptance index has unknown IDs: #{extra.join(', ')}" unless extra.empty?
end

conformance_path = ROOT.join("openspec/verification/core-conformance.yaml")
case_minimum_evidence = {}
case_definitions = {}
conformance_fixture_ids = []
if conformance_path.exist?
  conformance = YAML.safe_load(
    conformance_path.read,
    permitted_classes: [Date, Time],
    aliases: true,
    filename: conformance_path.to_s
  )
  index = conformance.fetch("acceptance_index", {})
  if index_path.exist?
    actual_index_hash = Digest::SHA256.file(index_path).hexdigest
    errors << "conformance acceptance-index hash mismatch" unless index["sha256"] == actual_index_hash
    indexed_count = index_path.readlines.count { |line| !line.strip.empty? && !line.start_with?("#") }
    errors << "conformance acceptance-index count mismatch" unless index["count"] == indexed_count
  end
  cases_entry = conformance.fetch("acceptance_cases", {})
  cases_path = ROOT.join(cases_entry.fetch("path", "missing"))
  if !cases_path.file?
    errors << "conformance acceptance cases file is missing"
  else
    actual_cases_hash = Digest::SHA256.file(cases_path).hexdigest
    errors << "conformance acceptance-cases hash mismatch" unless cases_entry["sha256"] == actual_cases_hash
    cases_document = YAML.safe_load(cases_path.read, aliases: true) || {}
    cases = Array(cases_document["cases"])
    case_ids = cases.map { |item| item["acceptance_id"] }
    test_ids = cases.map { |item| item["test_id"] }
    errors << "acceptance cases count mismatch" unless cases_entry["count"] == cases.length
    errors << "acceptance cases do not exactly cover current AC IDs" unless case_ids.sort == acceptance.keys.sort
    errors << "acceptance cases contain duplicate AC IDs" unless case_ids.uniq.length == case_ids.length
    errors << "acceptance cases contain duplicate Test IDs" unless test_ids.uniq.length == test_ids.length
    allowed_evidence = cases_document.fetch("evidence_classes", {}).keys
    cases.each do |item|
      case_minimum_evidence[item["acceptance_id"]] = item["minimum_evidence"]
      %w[acceptance_id test_id method expected_source minimum_evidence].each do |field|
        errors << "acceptance case #{item['acceptance_id'] || '?'} missing #{field}" if item[field].to_s.empty?
      end
      errors << "acceptance case #{item['acceptance_id']} has unknown evidence class" unless allowed_evidence.include?(item["minimum_evidence"])
      if item["minimum_evidence"] == "realHardware"
        errors << "acceptance case #{item['acceptance_id']} lacks a closed hardware capability" unless %w[hdcConnectivity uiDump trace debug flash].include?(item["hardware_capability"])
      elsif item.key?("hardware_capability")
        errors << "non-hardware acceptance case #{item['acceptance_id']} declares a hardware capability"
      end
      source_path, source_anchor = item["expected_source"].to_s.split("#", 2)
      source = ROOT.join(source_path.to_s)
      scenario_block = nil
      if !source.file?
        errors << "acceptance case #{item['acceptance_id']} source file missing"
      else
        source_text = source.read
        scenario_block = canonical_markdown_block(
          source_text,
          /^#### Scenario: #{Regexp.escape(item['acceptance_id'].to_s)}\b.*$/,
          /^\#{1,4} /
        )
      end
      if source.file? && (source_anchor != item["acceptance_id"] || scenario_block.nil?)
        errors << "acceptance case #{item['acceptance_id']} expected_source does not resolve"
      end
      definition = item.dup
      definition["source_sha256"] = Digest::SHA256.hexdigest(scenario_block) if scenario_block
      case_definitions[item["acceptance_id"]] = definition
    end
  end
  walk_hash_entries(conformance.fetch("shared_inputs", {})) do |entry|
    input_path = ROOT.join(entry.fetch("path"))
    if !input_path.file?
      errors << "conformance input missing: #{entry.fetch('path')}"
    elsif Digest::SHA256.file(input_path).hexdigest != entry.fetch("sha256")
      errors << "conformance input hash mismatch: #{entry.fetch('path')}"
    end
  end
  conformance_fixture_ids = Array(conformance.dig("shared_inputs", "fixtures")).map { |entry| entry["id"] }.compact
  conformance.fetch("safety_coverage", []).each do |group|
    Array(group["invariants"]).each do |id|
      errors << "conformance safety coverage has unknown Policy #{id}" unless policies.key?(id)
    end
    errors << "conformance safety coverage group has no invariant" if Array(group["invariants"]).empty?
    Array(group["requirements"]).each do |id|
      errors << "conformance safety coverage has unknown Requirement #{id}" unless requirements.key?(id)
    end
    %w[normal refusal_or_failure recovery_or_restart].each do |category|
      value = group[category]
      if value.is_a?(Hash)
        reason = value["not_applicable_reason"]
        errors << "#{group['invariants']} #{category} has invalid Core not-applicable rationale" if reason.to_s.empty? || value.keys != ["not_applicable_reason"]
      elsif value.is_a?(Array) && !value.empty?
        value.each do |id|
          errors << "conformance safety coverage has unknown Acceptance #{id}" unless acceptance.key?(id)
        end
      else
        errors << "#{group['invariants']} #{category} must have AC IDs or a Core rationale"
      end
    end
  end
  if conformance["status"] == "review"
    errors << "review conformance gate must be closed" unless conformance["execution_gate"] == "closed"
  elsif conformance["status"] == "accepted"
    errors << "accepted conformance gate must be open" unless conformance["execution_gate"] == "open"
    errors << "accepted conformance needs approval_ref" if conformance.dig("ratification", "approval_ref").to_s.empty?
  end
end

core_case_definitions = case_definitions.transform_values(&:dup)
live_change_proposals = {}
change_schemas = {}
behavior_overlays = {}
configured_core_baseline = (YAML.safe_load(ROOT.join("openspec/config.yaml").read, aliases: false) || {})["current_core_baseline"]
Dir.glob(ROOT.join("openspec/changes/chg-*/proposal.md")).sort.each do |proposal_path_string|
  proposal_path = Pathname.new(proposal_path_string)
  proposal = markdown_frontmatter(proposal_path)
  change_id = proposal["id"]
  next if change_id.to_s.empty?

  live_change_proposals[change_id] = proposal
  change_schemas[change_id] = proposal["schema"]
  next unless proposal["schema"] == "arkdeck-behavior"

  errors << "behavior change #{change_id} does not pin the configured Core baseline" unless proposal["core_baseline"] == configured_core_baseline
  delta_paths = Dir.glob(proposal_path.parent.join("specs/**/*.md").to_s).sort
  if delta_paths.empty?
    errors << "behavior change #{change_id} has no delta spec"
    next
  end
  delta_sources = delta_paths.map do |delta_path|
    { "path" => relative(delta_path), "text" => File.read(delta_path) }
  end
  behavior_overlays[change_id] = build_behavior_overlay(
    delta_sources: delta_sources,
    baseline_requirement_acceptance: baseline_requirement_acceptance,
    baseline_acceptance_owner: baseline_acceptance_owner,
    baseline_requirement_paths: baseline_requirement_paths,
    errors: errors,
    subject: "behavior change #{change_id}"
  )
end

behavior_case_definitions = Hash.new { |hash, key| hash[key] = {} }
Dir.glob(ROOT.join("openspec/changes/**/acceptance-cases.yaml")).sort.each do |path|
  next if relative(path).include?("/archive/")

  document = YAML.safe_load(File.read(path), aliases: true) || {}
  change_root = Pathname.new(path).parent
  expected_change_id = change_root.basename.to_s.sub(/\Achg-/, "CHG-")
  registry_proposal = change_root.join("proposal.md").file? ? markdown_frontmatter(change_root.join("proposal.md")) : {}
  change_id = document["change_id"]
  errors << "acceptance registry change ID mismatch: #{relative(path)}" unless change_id.to_s.downcase == expected_change_id.downcase && registry_proposal["id"] == change_id
  errors << "acceptance registry revision is not immutable V1: #{relative(path)}" unless document["change_revision"] == 1 && registry_proposal["revision"] == 1
  errors << "acceptance registry #{relative(path)} has an unsupported schema_version" unless document["schema_version"] == "1.0.0"
  allowed_evidence = Array(document["evidence_classes"])
  errors << "acceptance registry #{relative(path)} has duplicate/unknown evidence classes" unless allowed_evidence.uniq.length == allowed_evidence.length && (allowed_evidence - ACCEPTANCE_EVIDENCE_CLASSES).empty?
  cases = Array(document["cases"])
  case_ids = cases.map { |item| item["acceptance_id"] }
  test_ids = cases.map { |item| item["test_id"] }
  errors << "acceptance registry #{relative(path)} has duplicate Acceptance IDs" unless case_ids.uniq.length == case_ids.length
  errors << "acceptance registry #{relative(path)} has duplicate Test IDs" unless test_ids.uniq.length == test_ids.length

  if registry_proposal["schema"] == "arkdeck-behavior"
    expected_fields = %w[cases change_id change_revision core_baseline evidence_classes schema_version]
    errors << "behavior acceptance registry #{relative(path)} has an invalid shape" unless document.keys.map(&:to_s).sort == expected_fields
    errors << "behavior acceptance registry #{relative(path)} baseline mismatch" unless document["core_baseline"] == registry_proposal["core_baseline"] && document["core_baseline"] == configured_core_baseline
    overlay = behavior_overlays[change_id]
    if overlay.nil?
      errors << "behavior acceptance registry #{relative(path)} has no parsed baseline+delta overlay"
      next
    end
    errors << "behavior acceptance registry #{relative(path)} does not exactly cover changed ACs" unless case_ids.sort == overlay["touched_acceptance"]
    cases.each do |item|
      id = item["acceptance_id"]
      unless id.to_s.match?(CORE_ACCEPTANCE_ID)
        errors << "invalid behavior acceptance ID #{id || '?'} in #{relative(path)}"
        next
      end
      %w[test_id method expected_source source_sha256 minimum_evidence].each do |field|
        errors << "behavior acceptance #{id} missing #{field}" if item[field].to_s.empty?
      end
      allowed_item_fields = %w[acceptance_id expected_source hardware_capability method minimum_evidence source_sha256 test_id]
      errors << "behavior acceptance #{id} has unknown fields" unless (item.keys.map(&:to_s) - allowed_item_fields).empty?
      errors << "behavior acceptance #{id} has an invalid Test ID" unless item["test_id"].to_s.match?(/\A[A-Z][A-Z0-9-]+\z/)
      errors << "behavior acceptance #{id} has an invalid Scenario block hash" unless item["source_sha256"].to_s.match?(/\A[a-f0-9]{64}\z/)
      errors << "behavior acceptance #{id} has unknown evidence class" unless allowed_evidence.include?(item["minimum_evidence"])
      if item["minimum_evidence"] == "realHardware"
        errors << "behavior acceptance #{id} lacks a closed hardware capability" unless %w[hdcConnectivity uiDump trace debug flash].include?(item["hardware_capability"])
      elsif item.key?("hardware_capability")
        errors << "non-hardware behavior acceptance #{id} declares a hardware capability"
      end
      source_path, source_anchor = item["expected_source"].to_s.split("#", 2)
      source = ROOT.join(source_path.to_s).expand_path
      scenario_metadata = overlay.dig("scenario_sources", id) || {}
      source_contained = source.to_s.start_with?("#{change_root.expand_path}#{File::SEPARATOR}")
      valid_source = source_contained && source.file? && source_anchor == id &&
                     source_path == scenario_metadata["path"] && source_anchor == scenario_metadata["anchor"] &&
                     item["source_sha256"] == scenario_metadata["block_sha256"] &&
                     source.read.include?("#### Scenario: #{id}")
      errors << "behavior acceptance #{id} expected_source/hash does not resolve to its exact delta Scenario" unless valid_source
      behavior_case_definitions[change_id][id] = item.merge("change_id" => change_id, "kind" => "behaviorOverlay")
    end
  elsif registry_proposal["schema"] == "arkdeck-platform"
    expected_fields = %w[cases change_id change_revision evidence_classes platform schema_version]
    errors << "platform acceptance registry #{relative(path)} has an invalid shape" unless document.keys.map(&:to_s).sort == expected_fields
    registry_platform = document["platform"].to_s
    errors << "platform acceptance registry has invalid platform: #{relative(path)}" unless %w[macos windows linux].include?(registry_platform)
    cases.each do |item|
      id = item["acceptance_id"]
      unless id.to_s.match?(PLATFORM_ACCEPTANCE_ID)
        errors << "invalid platform acceptance ID in #{relative(path)}"
        next
      end
      errors << "duplicate platform/Core acceptance #{id}" if case_definitions.key?(id) || platform_acceptance.key?(id)
      %w[test_id method expected_result expected_source minimum_evidence].each do |field|
        errors << "platform acceptance #{id} missing #{field}" if item[field].to_s.empty?
      end
      allowed_item_fields = %w[acceptance_id expected_result expected_source hardware_capability method minimum_evidence test_id]
      errors << "platform acceptance #{id} has unknown fields" unless (item.keys.map(&:to_s) - allowed_item_fields).empty?
      errors << "platform acceptance #{id} has an invalid Test ID" unless item["test_id"].to_s.match?(/\A[A-Z][A-Z0-9-]+\z/)
      errors << "platform acceptance #{id} has unknown evidence class" unless allowed_evidence.include?(item["minimum_evidence"])
      if item["minimum_evidence"] == "realHardware"
        errors << "platform acceptance #{id} lacks a closed hardware capability" unless %w[hdcConnectivity uiDump trace debug flash].include?(item["hardware_capability"])
      elsif item.key?("hardware_capability")
        errors << "non-hardware platform acceptance #{id} declares a hardware capability"
      end
      source_path, source_anchor = item["expected_source"].to_s.split("#", 2)
      source = ROOT.join(source_path.to_s)
      if !source.file? || source_anchor != id || !source.read.include?(id)
        errors << "platform acceptance #{id} expected_source does not resolve"
      end
      platform_acceptance[id] = { "path" => relative(path), "change_id" => change_id, "platform" => registry_platform }
      case_minimum_evidence[id] = item["minimum_evidence"]
      case_definitions[id] = item.merge("platform" => registry_platform, "change_id" => change_id)
    end
  else
    errors << "acceptance registry #{relative(path)} belongs to an unknown change schema"
  end
end

platform_case_identity_locations = Hash.new { |hash, key| hash[key] = [] }
platform_change_case_records = []
Dir.glob(ROOT.join("openspec/changes/**/acceptance-cases.yaml")).sort.each do |path|
  change_root = Pathname.new(path).parent
  proposal_path = change_root.join("proposal.md")
  next unless proposal_path.file? && markdown_frontmatter(proposal_path)["schema"] == "arkdeck-platform"

  registry = YAML.safe_load(File.read(path), aliases: false) || {}
  platform = registry["platform"].to_s
  Array(registry["cases"]).each do |item|
    acceptance_id = item["acceptance_id"]
    platform_case_identity_locations[acceptance_id] << relative(path)
    platform_change_case_records << { "id" => acceptance_id, "platform" => platform, "definition" => item }
  end
end
platform_case_identity_locations.each do |acceptance_id, paths|
  errors << "platform acceptance identity #{acceptance_id} is reused across Change history: #{paths.sort.join(', ')}" if paths.length > 1
end

case_definition_for_change = lambda do |change_id, acceptance_id|
  behavior_case_definitions.dig(change_id, acceptance_id) ||
    if platform_acceptance.dig(acceptance_id, "change_id") == change_id
      case_definitions[acceptance_id]
    else
      core_case_definitions[acceptance_id]
    end
end
acceptance_known_for_change = lambda do |change_id, acceptance_id|
  overlay = behavior_overlays[change_id]
  if overlay
    overlay["reference_acceptance"].include?(acceptance_id)
  else
    acceptance.key?(acceptance_id) || platform_acceptance.dig(acceptance_id, "change_id") == change_id
  end
end
requirement_known_for_change = lambda do |change_id, requirement_id|
  overlay = behavior_overlays[change_id]
  if requirement_id.start_with?("REQ-")
    overlay ? overlay["reference_requirements"].include?(requirement_id) : requirements.key?(requirement_id)
  elsif requirement_id.start_with?("POL-")
    policies.key?(requirement_id)
  elsif requirement_id.start_with?("PORT-")
    ports.key?(requirement_id)
  else
    requirement_id.start_with?("PLATFORM-")
  end
end

integration_lock_path = ROOT.join("openspec/integrations/INTEGRATION-PROFILES.lock.yaml")
integration_lock = nil
integration_locked_profiles = {}
if integration_lock_path.file?
  integration_lock = YAML.safe_load(integration_lock_path.read, permitted_classes: [Date, Time], aliases: true) || {}
  all_entries = Array(integration_lock["profiles"]) + Array(integration_lock["catalogs"]) + Array(integration_lock["fixtures"])
  paths = all_entries.map { |entry| entry["path"] }
  errors << "integration lock has duplicate paths" unless paths.uniq.length == paths.length
  all_entries.each do |entry|
    path = ROOT.join(entry["path"].to_s)
    if !path.file?
      errors << "integration lock path missing: #{entry['path']}"
    elsif Digest::SHA256.file(path).hexdigest != entry["sha256"]
      errors << "integration lock hash mismatch: #{entry['path']}"
    end
  end
  expected_profiles = Dir.glob(ROOT.join("openspec/integrations/**/profile.md")).map { |path| relative(path) }.sort
  expected_catalogs = %w[
    openspec/contracts/catalogs/debug-parameters.yaml
    openspec/contracts/catalogs/dump-recipes.yaml
    openspec/contracts/catalogs/trace-presets.yaml
  ].select { |path| ROOT.join(path).file? }.sort
  expected_fixtures = Dir.glob(ROOT.join("openspec/integrations/fixtures/**/*")).select { |path| File.file?(path) }.map { |path| relative(path) }.sort
  errors << "integration lock profile set is incomplete" unless Array(integration_lock["profiles"]).map { |entry| entry["path"] }.sort == expected_profiles
  errors << "integration lock catalog set is incomplete" unless Array(integration_lock["catalogs"]).map { |entry| entry["path"] }.sort == expected_catalogs
  errors << "integration lock fixture set is incomplete" unless Array(integration_lock["fixtures"]).map { |entry| entry["path"] }.sort == expected_fixtures
  Array(integration_lock["profiles"]).each do |entry|
    if integration_locked_profiles.key?(entry["id"])
      errors << "integration lock has duplicate profile ID #{entry['id']}"
    else
      integration_locked_profiles[entry["id"]] = entry
    end
    profile_path = ROOT.join(entry["path"].to_s)
    if profile_path.file?
      text = profile_path.read
      profile_id = text[/^> ID：([^\s]+)\s*$/, 1]
      profile_version = text[/^> Version：([^\s]+)\s*$/, 1]
      errors << "integration lock profile metadata mismatch: #{entry['path']}" unless profile_id == entry["id"] && profile_version == entry["version"]
    end
  end
  Array(integration_lock["catalogs"]).each do |entry|
    catalog_path = ROOT.join(entry["path"].to_s)
    next unless catalog_path.file?

    catalog = YAML.safe_load(catalog_path.read, aliases: true) || {}
    errors << "integration lock catalog metadata mismatch: #{entry['path']}" unless catalog["catalog"] == entry["id"] && (catalog["version"] || catalog["schema_version"]) == entry["version"]
  end
  if integration_lock["status"] == "review"
    errors << "review integration lock gate must be closed" unless integration_lock["execution_gate"] == "closed"
    errors << "review integration lock must not have accepted_at" unless integration_lock["accepted_at"].nil?
  elsif integration_lock["status"] == "accepted"
    errors << "accepted integration lock gate must be open" unless integration_lock["execution_gate"] == "open"
    errors << "accepted integration lock needs approval_ref" if integration_lock.dig("ratification", "approval_ref").to_s.empty?
  end
else
  errors << "integration lock is missing"
end

if conformance && integration_lock
  lock_ref = conformance.dig("shared_inputs", "integration_lock") || {}
  unless lock_ref["id"] == integration_lock["lock"] &&
         lock_ref["path"] == relative(integration_lock_path) &&
         lock_ref["sha256"] == Digest::SHA256.file(integration_lock_path).hexdigest
    errors << "conformance suite does not pin the current Integration lock"
  end
  accepted_input_entries = (Array(integration_lock["profiles"]) + Array(integration_lock["catalogs"]) + Array(integration_lock["fixtures"])).to_h { |entry| [entry["path"], entry] }
  conformance_integration_entries = Array(conformance.dig("shared_inputs", "integration_profiles")) +
                                    Array(conformance.dig("shared_inputs", "catalogs")).reject { |entry| entry["path"] == "openspec/contracts/catalogs/remote-operations.yaml" } +
                                    Array(conformance.dig("shared_inputs", "fixtures"))
  conformance_integration_entries.each do |entry|
    locked = accepted_input_entries[entry["path"]]
    errors << "conformance integration input is not in the Integration lock: #{entry['path']}" unless locked && locked["sha256"] == entry["sha256"]
  end
end

project_config = YAML.safe_load(ROOT.join("openspec/config.yaml").read, aliases: true) || {}
declared_platforms = Array(project_config["declared_target_platforms"]).map(&:to_s).sort
profile_platforms = Dir.glob(ROOT.join("openspec/platforms/*/profile.md")).map { |path| Pathname.new(path).parent.basename.to_s }.sort
errors << "declared target platform set differs from platform profiles" unless declared_platforms == profile_platforms
errors << "Core config must not carry current-delivery/not-started lifecycle state" if project_config.key?("current_delivery_platforms") || project_config.key?("not_started_platforms")

platform_lock_path = ROOT.join("openspec/platforms/PLATFORM-PROFILES.lock.yaml")
platform_lock = nil
platform_lock_chain = []
platform_history_records = []
platform_case_definitions = {}
platform_support_definitions = {}
if platform_lock_path.file?
  platform_lock = YAML.safe_load(platform_lock_path.read, permitted_classes: [Date, Time], aliases: true)
  platform_history_paths = Dir.glob(ROOT.join("openspec/platforms/history/*.lock.yaml")).sort
  platform_history_records = platform_history_paths.map do |history_path|
    {
      "path" => Pathname.new(history_path),
      "document" => YAML.safe_load(File.read(history_path), permitted_classes: [Date, Time], aliases: true) || {}
    }
  end
  current_revision = platform_lock["revision"]
  history_revisions = platform_history_records.map { |record| record.dig("document", "revision") }
  if !current_revision.is_a?(Integer) || current_revision < 1
    errors << "platform lock has an invalid revision"
  elsif !history_revisions.all? { |revision| revision.is_a?(Integer) && revision >= 1 }
    errors << "platform lock history has an invalid revision"
  else
    errors << "platform lock history does not exactly cover prior revisions" unless history_revisions.sort == (1...current_revision).to_a
  end
  errors << "platform lock history has duplicate revisions" unless history_revisions.uniq.length == history_revisions.length
  platform_lock_chain = platform_history_records.sort_by { |record| record.dig("document", "revision").to_i } +
                        [{ "path" => platform_lock_path, "document" => platform_lock }]
  expected_last_verified_fields = %w[approval_id case_manifest_sha256 conformance_suite_sha256 core_baseline core_baseline_sha256 evidence_path evidence_sha256 integration_lock_sha256 profile_sha256 release_subject_approval_id release_subject_path release_subject_sha256 support_matrix_sha256 valid_until verification_sha256]
  platform_lock_chain.each_with_index do |record, index|
    document = record["document"]
    path = record["path"]
    expected_revision = index + 1
    errors << "platform lock chain revision is not exact at #{relative(path)}" unless document["revision"] == expected_revision
    if path != platform_lock_path
      errors << "historical platform lock #{relative(path)} is not accepted" unless document["status"] == "accepted" && document["execution_gate"] == "open"
      errors << "historical platform lock #{relative(path)} lacks accepted_at/approval_ref" if document["accepted_at"].to_s.empty? || document.dig("ratification", "approval_ref").to_s.empty?
    end
    historical_profiles = Array(document["profiles"])
    errors << "platform lock #{relative(path)} has duplicate IDs" unless historical_profiles.map { |entry| entry["id"] }.uniq.length == historical_profiles.length
    errors << "platform lock #{relative(path)} has duplicate platform bindings" unless historical_profiles.map { |entry| entry["platform"] }.uniq.length == historical_profiles.length
    historical_profiles.each do |entry|
      errors << "platform lock #{relative(path)} has invalid conformance status: #{entry['id']}" unless %w[notStarted verified needsReverification nonConformant].include?(entry["conformance_status"])
      last_verified = entry["last_verified"]
      unless last_verified.is_a?(Hash) && last_verified.keys.map(&:to_s).sort == expected_last_verified_fields
        errors << "platform lock #{relative(path)} has invalid last_verified shape: #{entry['id']}"
      end
    end
    validate_platform_lifecycle(
      errors: errors,
      subject: "platform lock #{relative(path)}",
      lock: document,
      declared_platforms: declared_platforms
    )

    previous_ref = document["previous_lock"]
    if index.zero?
      errors << "first platform lock revision must not reference a predecessor" unless previous_ref.nil?
      next
    end

    prior_record = platform_lock_chain[index - 1]
    prior_path = prior_record["path"]
    valid_ref = previous_ref.is_a?(Hash) &&
                previous_ref["path"] == relative(prior_path) &&
                previous_ref["sha256"] == Digest::SHA256.file(prior_path).hexdigest &&
                previous_ref["path"].to_s.match?(/\Aopenspec\/platforms\/history\/PLATFORM-PROFILES-[A-Za-z0-9._-]+\.lock\.yaml\z/)
    errors << "platform lock #{relative(path)} predecessor path/hash is not the exact prior revision" unless valid_ref
    validate_platform_transition(
      errors: errors,
      subject: "platform lock transition #{expected_revision - 1}->#{expected_revision}",
      prior: prior_record["document"],
      current: document
    )
  end
  profile_entries = platform_lock.fetch("profiles", [])
  errors << "platform lock has duplicate IDs" unless profile_entries.map { |entry| entry["id"] }.uniq.length == profile_entries.length
  errors << "platform lock has duplicate platform bindings" unless profile_entries.map { |entry| entry["platform"] }.uniq.length == profile_entries.length
  expected_profile_paths = Dir.glob(ROOT.join("openspec/platforms/*/profile.md")).map { |path| relative(path) }.sort
  expected_verification_paths = Dir.glob(ROOT.join("openspec/platforms/*/verification.md")).map { |path| relative(path) }.sort
  expected_case_manifest_paths = Dir.glob(ROOT.join("openspec/platforms/*/conformance-cases.yaml")).map { |path| relative(path) }.sort
  errors << "platform lock does not exactly cover platform profiles" unless profile_entries.map { |entry| entry["profile_path"] }.sort == expected_profile_paths
  errors << "platform lock does not exactly cover platform verification profiles" unless profile_entries.map { |entry| entry["verification_path"] }.sort == expected_verification_paths
  errors << "platform lock does not exactly cover platform case manifests" unless profile_entries.map { |entry| entry["case_manifest_path"] }.sort == expected_case_manifest_paths
  profile_entries.each do |entry|
    {
      entry.fetch("profile_path") => entry.fetch("profile_sha256"),
      entry.fetch("verification_path") => entry.fetch("verification_sha256"),
      entry.fetch("case_manifest_path") => entry.fetch("case_manifest_sha256")
    }.each do |locked_path, locked_hash|
      path = ROOT.join(locked_path)
      if !path.file?
        errors << "platform lock path missing: #{locked_path}"
      elsif Digest::SHA256.file(path).hexdigest != locked_hash
        errors << "platform lock hash mismatch: #{locked_path}"
      end
    end
    profile_text = ROOT.join(entry.fetch("profile_path")).read
    profile_id = profile_text[/^> ID：([^\s]+)\s*$/, 1]
    profile_version = profile_text[/^> Version：([^\s]+)\s*$/, 1]
    core_strategy = profile_text[/^> Core strategy：([^\s]+)\s*$/, 1]
    errors << "platform lock metadata mismatch: #{entry['profile_path']}" unless profile_id == entry["id"] && profile_version == entry["version"]
    errors << "platform profile does not fix the V1 native/shared-suite Core strategy: #{entry['profile_path']}" unless core_strategy == "native-conforming-shared-contract-vector-suite"
    expected_platform = Pathname.new(entry.fetch("profile_path")).parent.basename.to_s
    errors << "platform lock profile/platform binding mismatch: #{entry['id']}" unless entry["platform"] == expected_platform
    case_manifest_path = ROOT.join(entry.fetch("case_manifest_path"))
    case_manifest = case_manifest_path.file? ? (YAML.safe_load(case_manifest_path.read, aliases: true) || {}) : {}
    case_ids = Array(case_manifest["cases"]).map { |item| item["id"] }
    case_test_ids = Array(case_manifest["cases"]).map { |item| item["test_id"] }
    support_cells = Array(case_manifest["support_cells"])
    support_cell_ids = support_cells.map { |item| item["id"] }
    valid_case_manifest = case_manifest["platform"] == entry["platform"] && case_manifest["version"] == entry["version"] &&
                          !case_manifest["suite"].to_s.empty? && !case_ids.empty? &&
                          case_ids.uniq.length == case_ids.length && case_test_ids.uniq.length == case_test_ids.length &&
                          !support_cells.empty? && support_cell_ids.uniq.length == support_cell_ids.length &&
                          support_cells.all? do |item|
                            item.keys.map(&:to_s).sort == %w[architecture id os_version_family package_format] &&
                              item["id"].to_s.match?(/\A[a-z][a-z0-9-]+\z/) &&
                              %w[os_version_family architecture package_format].all? { |field| !item[field].to_s.empty? }
                          end &&
                          Array(case_manifest["cases"]).all? do |item|
                            expected_source_path, expected_anchor = item["expected_source"].to_s.split("#", 2)
                            source = ROOT.join(expected_source_path.to_s)
                            item["id"].to_s.match?(/\A[A-Z][A-Z0-9-]+\z/) && item["test_id"].to_s.match?(/\ATEST-[A-Z0-9-]+\z/) &&
                              !item["method"].to_s.empty? && !item["expected_result"].to_s.empty? &&
                              %w[platform manualReview realHardware].include?(item["minimum_evidence"]) &&
                              (item["minimum_evidence"] == "realHardware" ? %w[hdcConnectivity uiDump trace debug flash].include?(item["hardware_capability"]) : !item.key?("hardware_capability")) &&
                              source.file? && expected_anchor == item["id"] && source.read.include?(item["id"])
                          end
    errors << "platform case manifest is invalid: #{entry['case_manifest_path']}" unless valid_case_manifest
    platform_case_definitions[entry["platform"]] = Array(case_manifest["cases"]) if valid_case_manifest
    platform_support_definitions[entry["platform"]] = support_cells if valid_case_manifest
    release_subject = entry["release_subject"]
    expected_release_subject_fields = %w[approval_id path sha256]
    errors << "platform #{entry['platform']} has an invalid release_subject shape" unless release_subject.is_a?(Hash) && release_subject.keys.map(&:to_s).sort == expected_release_subject_fields
    unless %w[notStarted verified needsReverification nonConformant].include?(entry["conformance_status"])
      errors << "platform lock has invalid conformance status: #{entry['id']}"
    end
    last_verified = entry["last_verified"]
    unless last_verified.is_a?(Hash) && last_verified.keys.map(&:to_s).sort == expected_last_verified_fields
      errors << "platform lock has invalid last_verified shape: #{entry['id']}"
    end
    mapped_ports = profile_text.scan(/^\| ([A-Za-z][A-Za-z0-9]+) \|/).flatten.select { |name| port_names.include?(name) }
    errors << "platform profile Port mapping is incomplete: #{entry['profile_path']}" unless mapped_ports.sort == port_names.sort
  end
  if platform_lock["status"] == "review"
    errors << "review platform lock gate must be closed" unless platform_lock["execution_gate"] == "closed"
    errors << "review platform lock must not have accepted_at" unless platform_lock["accepted_at"].nil?
  elsif platform_lock["status"] == "accepted"
    errors << "accepted platform lock gate must be open" unless platform_lock["execution_gate"] == "open"
    errors << "accepted platform lock needs approval_ref" if platform_lock.dig("ratification", "approval_ref").to_s.empty?
  end
end

platform_change_case_records.each do |record|
  release_definition = Array(platform_case_definitions[record["platform"]]).find { |definition| definition["id"] == record["id"] }
  next unless release_definition

  local_hash = acceptance_case_contract_sha256(record["id"], record["definition"])
  release_hash = acceptance_case_contract_sha256(record["id"], release_definition)
  errors << "platform acceptance #{record['id']} differs from its #{record['platform']} release-case contract" unless local_hash == release_hash
end

registry_path = ROOT.join("openspec/contracts/workflow-step-registry.yaml")
workflow_schema_path = ROOT.join("openspec/contracts/workflow-step.schema.json")
if registry_path.file? && workflow_schema_path.file?
  registry = YAML.safe_load(registry_path.read, aliases: true)
  workflow_schema = JSON.parse(workflow_schema_path.read)
  definitions = workflow_schema.fetch("$defs")
  schema_kinds = definitions.fetch("kind").fetch("enum")
  registry_steps = registry.fetch("steps")
  registry_kinds = registry_steps.map { |step| step.fetch("kind") }
  errors << "workflow registry has duplicate kinds" unless registry_kinds.uniq.length == registry_kinds.length
  errors << "workflow registry and schema kind sets differ" unless registry_kinds.sort == schema_kinds.sort

  argument_kinds = definitions.fetch("typedArgumentsByKind").fetch("allOf").flat_map do |rule|
    kind_rule = rule.dig("if", "properties", "kind") || {}
    kind_rule.key?("const") ? [kind_rule["const"]] : Array(kind_rule["enum"])
  end.uniq
  errors << "not every workflow kind has exactly one typed argument mapping" unless argument_kinds.sort == schema_kinds.sort

  effect_order = %w[hostOnly readOnly deviceMutation destructive]
  cancellation_order = %w[immediate atSafeBoundary criticalNonInterruptible]
  binding_order = %w[none confirmedDevice]
  rules = definitions.fetch("typedStepInvariants").fetch("allOf")
  registry_steps.each do |step|
    kind = step.fetch("kind")
    actual = {
      "effect" => effect_order.dup,
      "cancellation" => cancellation_order.dup,
      "bindingRequirement" => binding_order.dup
    }
    rules.each do |rule|
      kind_rule = rule.dig("if", "properties", "kind") || {}
      covered = kind_rule["const"] == kind || Array(kind_rule["enum"]).include?(kind)
      next unless covered

      %w[effect cancellation bindingRequirement].each do |field|
        constraint = rule.dig("then", "properties", field)
        next unless constraint

        permitted = constraint.key?("const") ? [constraint["const"]] : Array(constraint["enum"])
        actual[field] &= permitted
      end
    end
    expected = {
      "effect" => effect_order.drop(effect_order.index(step.fetch("minimum_effect"))),
      "cancellation" => cancellation_order.drop(cancellation_order.index(step.fetch("cancellation"))),
      "bindingRequirement" => if step["binding_exact"]
                                [step.fetch("binding")]
                              else
                                binding_order.drop(binding_order.index(step.fetch("binding")))
                              end
    }
    expected.each do |field, values|
      errors << "workflow schema #{kind} #{field} differs from registry minimum" unless actual[field] == values
    end
  end

  dump_catalog = YAML.safe_load(ROOT.join("openspec/contracts/catalogs/dump-recipes.yaml").read, aliases: true)
  trace_catalog = YAML.safe_load(ROOT.join("openspec/contracts/catalogs/trace-presets.yaml").read, aliases: true)
  remote_catalog = YAML.safe_load(ROOT.join("openspec/contracts/catalogs/remote-operations.yaml").read, aliases: true)
  dump_ids = (Array(dump_catalog["recipes"]) + Array(dump_catalog["legacy_fallbacks"])).map { |entry| entry["id"] }.sort
  trace_ids = Array(trace_catalog["presets"]).map { |entry| entry["id"] }.sort
  stdout_arguments = definitions.fetch("catalogStdoutArguments").fetch("properties")
  errors << "stdout catalog ID is not closed" unless stdout_arguments.dig("catalogId", "const") == dump_catalog["catalog"]
  errors << "stdout dump action set differs from catalog" unless Array(stdout_arguments.dig("actionId", "enum")).sort == dump_ids
  file_branches = definitions.fetch("catalogFileArguments").fetch("allOf").first.fetch("oneOf")
  file_pairs = file_branches.to_h do |branch|
    properties = branch.fetch("properties")
    [properties.dig("catalogId", "const"), Array(properties.dig("actionId", "enum")).sort]
  end
  errors << "remote-file dump action set differs from catalog" unless file_pairs[dump_catalog["catalog"]] == dump_ids
  errors << "remote-file trace action set differs from catalog" unless file_pairs[trace_catalog["catalog"]] == trace_ids

  remote_by_kind = Array(remote_catalog["operations"]).group_by { |entry| entry["step_kind"] }
  {
    "runApprovedRemoteRead" => "approvedRemoteReadArguments",
    "runApprovedRemoteMutation" => "approvedRemoteMutationArguments"
  }.each do |kind, definition_name|
    argument_properties = definitions.fetch(definition_name).fetch("properties")
    catalog_operations = Array(remote_by_kind[kind])
    errors << "approved operation catalog ID is not closed for #{kind}" unless argument_properties.dig("catalogId", "const") == remote_catalog["catalog"]
    errors << "approved operation action set differs for #{kind}" unless Array(argument_properties.dig("actionId", "enum")).sort == catalog_operations.map { |entry| entry["id"] }.sort
    registry_step = registry_steps.find { |entry| entry["kind"] == kind }
    catalog_operations.each do |operation|
      next if registry_step &&
              operation["minimum_effect"] == registry_step["minimum_effect"] &&
              operation["cancellation"] == registry_step["cancellation"] &&
              operation["binding"] == registry_step["binding"]

      errors << "approved operation #{operation['id']} weakens #{kind} registry policy"
    end
  end
end

current_delivery_platforms = Array(platform_lock && platform_lock["current_delivery_platforms"]).map(&:to_s).sort
not_started_platforms = Array(platform_lock && platform_lock["not_started_platforms"]).map(&:to_s).sort
applicability = conformance.fetch("applicability", {})
errors << "conformance default platforms differ from declared targets" unless Array(applicability["default_platforms"]).map(&:to_s).sort == declared_platforms
errors << "Core conformance must not carry platform delivery/not-started lifecycle state" if applicability.key?("current_delivery_platforms") || applicability.key?("future_not_started_platforms") || applicability.key?("not_started_platforms")
errors << "Core conformance platform overrides are forbidden" unless Array(applicability["platform_overrides"]).empty?
if platform_lock
  locked_platforms = Array(platform_lock["profiles"]).map { |entry| entry["platform"].to_s }.sort
  errors << "platform lock bindings differ from declared target platforms" unless locked_platforms == declared_platforms
  Array(platform_lock["profiles"]).each do |entry|
    if not_started_platforms.include?(entry["platform"]) && entry["conformance_status"] != "notStarted"
      errors << "future/not-started platform #{entry['platform']} has an inconsistent conformance state"
    end
  end
else
  errors << "platform lock is missing"
end
current_core_baseline = project_config.fetch("current_core_baseline", "CORE-1.0.0")
baseline_path = ROOT.join("openspec/baselines/#{current_core_baseline}.lock.yaml")
if baseline_path.exist?
  baseline = YAML.safe_load(
    baseline_path.read,
    permitted_classes: [Date, Time],
    aliases: true,
    filename: baseline_path.to_s
  )
  lock_references = []
  walk_hash_entries(baseline) do |entry|
    lock_references << entry.fetch("path")
    locked_path = ROOT.join(entry.fetch("path"))
    if !locked_path.file?
      errors << "baseline path missing: #{entry.fetch('path')}"
    else
      actual_hash = Digest::SHA256.file(locked_path).hexdigest
      errors << "baseline hash mismatch: #{entry.fetch('path')}" unless actual_hash == entry.fetch("sha256")
    end
  end

  locked_paths = []
  file_manifest_ref = baseline["file_manifest"]
  if !file_manifest_ref.is_a?(Hash)
    errors << "baseline has no file_manifest"
  else
    file_manifest_path = ROOT.join(file_manifest_ref["path"].to_s)
    if file_manifest_path.file?
      file_manifest = YAML.safe_load(
        file_manifest_path.read,
        permitted_classes: [Date, Time],
        aliases: true,
        filename: file_manifest_path.to_s
      ) || {}
      errors << "baseline file manifest targets another baseline" unless file_manifest["baseline"] == baseline["baseline"]
      errors << "baseline file manifest hash algorithm differs" unless file_manifest["hash_algorithm"] == baseline["hash_algorithm"]
      entries = Array(file_manifest["files"])
      locked_paths = entries.map { |entry| entry["path"] }
      errors << "baseline file manifest has duplicate paths" unless locked_paths.uniq.length == locked_paths.length
      errors << "baseline file manifest is not path-sorted" unless locked_paths == locked_paths.sort
      entries.each do |entry|
        path = ROOT.join(entry["path"].to_s)
        if !path.file?
          errors << "baseline protected path missing: #{entry['path']}"
        elsif !entry["sha256"].to_s.match?(/\A[a-f0-9]{64}\z/)
          errors << "baseline protected path has invalid hash: #{entry['path']}"
        elsif Digest::SHA256.file(path).hexdigest != entry["sha256"]
          errors << "baseline protected hash mismatch: #{entry['path']}"
        end
      end
    end
  end

  # Protected-set definition is shared with relock-baseline.rb; see
  # scripts/sdd-protected-set.rb (itself part of the protected set).
  protected_files = sdd_protected_files(ROOT)
  missing_protected = protected_files - locked_paths
  errors << "baseline omits protected files: #{missing_protected.join(', ')}" unless missing_protected.empty?
  extra_locked = locked_paths - protected_files
  errors << "baseline file manifest contains non-protected files: #{extra_locked.join(', ')}" unless extra_locked.empty?
  errors << "baseline must hash exactly one file manifest" unless lock_references == [file_manifest_ref && file_manifest_ref["path"]]

  ratification = baseline.fetch("ratification", {})
  revalidation_context = baseline["platform_revalidation_context"].is_a?(Hash) ? baseline["platform_revalidation_context"] : {}
  revalidation_lock_record = platform_lock_chain.find do |record|
    document = record["document"]
    document["lock"] == revalidation_context["platform_lock"] &&
      document["revision"] == revalidation_context["revision"] &&
      Digest::SHA256.file(record["path"]).hexdigest == revalidation_context["sha256"]
  end
  context_current_delivery = Array(revalidation_context["current_delivery_platforms"]).map(&:to_s).sort
  valid_revalidation_context = revalidation_lock_record &&
                               context_current_delivery == Array(revalidation_lock_record.dig("document", "current_delivery_platforms")).map(&:to_s).sort
  errors << "Core baseline #{baseline['baseline']} lacks its exact ratification-time Platform lifecycle context" unless valid_revalidation_context
  validate_platform_revalidation(
    errors: errors,
    subject: "Core baseline #{baseline['baseline']}",
    matrix: baseline["platform_revalidation"],
    declared_platforms: declared_platforms,
    current_delivery_platforms: valid_revalidation_context ? context_current_delivery : []
  )
  if platform_lock
    current_conformance_hash = conformance_path.file? ? Digest::SHA256.file(conformance_path).hexdigest : nil
    current_baseline_hash = baseline_path.file? ? Digest::SHA256.file(baseline_path).hexdigest : nil
    current_integration_hash = integration_lock_path.file? ? Digest::SHA256.file(integration_lock_path).hexdigest : nil
    Array(platform_lock["profiles"]).each do |entry|
      state = entry["conformance_status"]
      last_verified = entry["last_verified"].is_a?(Hash) ? entry["last_verified"] : {}
      empty_last = !last_verified.empty? && last_verified.values.all?(&:nil?)
      complete_last = !last_verified.empty? && last_verified.values.all? { |value| !value.to_s.empty? }
      errors << "platform #{entry['platform']} has a partial last_verified record" unless empty_last || complete_last
      current_pins = {
      "profile_sha256" => entry["profile_sha256"],
      "verification_sha256" => entry["verification_sha256"],
      "case_manifest_sha256" => entry["case_manifest_sha256"],
      "release_subject_sha256" => entry.dig("release_subject", "sha256"),
      "release_subject_path" => entry.dig("release_subject", "path"),
      "release_subject_approval_id" => entry.dig("release_subject", "approval_id"),
        "core_baseline" => baseline["baseline"],
        "core_baseline_sha256" => current_baseline_hash,
        "conformance_suite_sha256" => current_conformance_hash,
        "integration_lock_sha256" => current_integration_hash
      }
      case state
      when "notStarted"
        errors << "platform #{entry['platform']} notStarted state carries a verified history" unless empty_last
        errors << "platform #{entry['platform']} notStarted state carries a release subject" unless entry["release_subject"].is_a?(Hash) && entry["release_subject"].values.all?(&:nil?)
      when "nonConformant"
        errors << "platform #{entry['platform']} nonConformant state has a partial verified history" unless empty_last || complete_last
      when "verified"
        errors << "platform #{entry['platform']} verified without a complete four-axis record" unless complete_last
        errors << "platform #{entry['platform']} verified without a complete protected release subject" unless entry["release_subject"].is_a?(Hash) && entry["release_subject"].values.all? { |value| !value.to_s.empty? }
        current_pins.each { |field, value| errors << "platform #{entry['platform']} verified #{field} is stale; mark needsReverification" unless last_verified[field] == value }
      when "needsReverification"
        errors << "platform #{entry['platform']} needsReverification state lacks the complete prior verified record" unless complete_last
        errors << "platform #{entry['platform']} needsReverification has no stale profile/Core/conformance/integration pin" if complete_last && current_pins.all? { |field, value| last_verified[field] == value }
      end
    end
  end
  if baseline["status"] == "accepted"
    errors << "accepted baseline must have accepted ratification" unless ratification["status"] == "accepted"
    errors << "accepted baseline execution gate must be open" unless ratification["execution_gate"] == "open"
    errors << "accepted baseline must have approval_ref" if ratification["approval_ref"].to_s.empty?
    errors << "accepted baseline must have accepted_at" if baseline["accepted_at"].to_s.empty?
  elsif baseline["status"] == "review"
    errors << "review baseline execution gate must be closed" unless ratification["execution_gate"] == "closed"
    errors << "review baseline must not have accepted_at" unless baseline["accepted_at"].nil?
  end
end

changes_root = ROOT.join("openspec/changes")
if changes_root.directory?
  changes_root.children.select(&:directory?).each do |path|
    next if path.basename.to_s == "archive"

    unless path.basename.to_s.match?(/\Achg-\d{4}-\d{3}-[a-z0-9]+(?:-[a-z0-9]+)*\z/)
      errors << "invalid change folder name: #{relative(path)}"
    end
  end
end

Dir.glob(ROOT.join("openspec/changes/**/proposal.md")).sort.each do |path|
  next if relative(path).include?("/archive/")

  proposal = markdown_frontmatter(path)
  if proposal["schema"] == "arkdeck-behavior" && !%w[minor major].include?(proposal["core_change_level"])
    errors << "behavior change #{proposal['id'] || relative(path)} must be MINOR or MAJOR in V1; PATCH lacks a machine proof that normative pass/fail semantics are unchanged"
  end
  next unless %w[minor major].include?(proposal["core_change_level"])

  validate_platform_revalidation(
    errors: errors,
    subject: "Core change #{proposal['id'] || relative(path)}",
    matrix: proposal["platform_revalidation"],
    declared_platforms: declared_platforms,
    current_delivery_platforms: current_delivery_platforms
  )
end

approval_schema = JSON.parse(ROOT.join("openspec/contracts/approval.schema.json").read)
approvals = {}
approval_paths = {}
Dir.glob(ROOT.join("openspec/approvals/**/*.json")).sort.each do |path|
  approval = JSON.parse(File.read(path))
  missing = approval_schema.fetch("required") - approval.keys
  extra = approval.keys - approval_schema.fetch("properties").keys
  errors << "approval #{relative(path)} missing #{missing.join(', ')}" unless missing.empty?
  errors << "approval #{relative(path)} has unknown fields #{extra.join(', ')}" unless extra.empty?
  if approval["mechanism"] == "detachedSignature" && approval["signature"].to_s.empty?
    errors << "detached-signature approval #{relative(path)} has no signature"
  end
  errors << "duplicate approval ID #{approval['approvalId']}" if approvals.key?(approval["approvalId"])
  if approval["decision"] == "approved" && (!git_commit?(approval["baseRevision"]) || !git_ancestor?(approval["baseRevision"], git_head_revision))
    errors << "approval #{relative(path)} baseRevision is not a canonical ancestor commit of the protected result"
  end
  approvals[approval["approvalId"]] = approval
  approval_paths[approval["approvalId"]] = path
end

# Change approval is also the execution-authorization boundary for its lineage.
# A successor only becomes effective when its exact change lock has an externally
# verified approval. Proposal links are validated even before approval so a later
# approval cannot turn a branch or cycle into an ambiguous authorization graph.
change_records = {}
Dir.glob(ROOT.join("openspec/changes/**/proposal.md")).sort.each do |path|
  proposal_path = Pathname.new(path)
  proposal = markdown_frontmatter(proposal_path)
  change_id = proposal["id"]
  if change_id.to_s.empty?
    errors << "change proposal #{relative(proposal_path)} has no ID"
    next
  end
  if change_records.key?(change_id)
    errors << "duplicate Change ID #{change_id}: #{relative(change_records[change_id]['proposal_path'])}, #{relative(proposal_path)}"
    next
  end

  lock_path = proposal_path.parent.join("change-lock.yaml")
  lock = lock_path.file? ? (YAML.safe_load(lock_path.read, aliases: false) || {}) : {}
  review_status = proposal_path.parent.join("review.md").file? ? proposal_path.parent.join("review.md").read[/^> Status：([^\s]+)\s*$/, 1] : nil
  ready_review_status = proposal_path.parent.join("ready-review.md").file? ? proposal_path.parent.join("ready-review.md").read[/^> Status：([^\s]+)\s*$/, 1] : nil
  approval = approvals[lock["approval_id"]]
  approval_path = approval && approval_paths[approval["approvalId"]]
  valid_approval = lock_path.file? && lock["status"] == "approved" &&
                   lock["change_id"] == change_id && lock["revision"] == proposal["revision"] &&
                   approval && approval_path && approval["subjectType"] == "change" &&
                   approval["subjectId"] == change_id && approval["subjectRevision"] == proposal["revision"] &&
                   approval["subjectSha256"] == Digest::SHA256.file(lock_path).hexdigest &&
                   review_status == "passed" && ready_review_status == "passed" &&
                   approval["decision"] == "approved" && git_commit?(approval["baseRevision"]) &&
                   externally_verified?(approval_path, lock_path, approval, trusted_verifiers)
  approved_at = nil
  if valid_approval
    begin
      approved_at = DateTime.iso8601(approval.fetch("approvedAt"))
    rescue KeyError, Date::Error
      errors << "approved Change #{change_id} has an invalid approval timestamp"
      valid_approval = false
    end
  end
  change_records[change_id] = {
    "proposal" => proposal,
    "proposal_path" => proposal_path,
    "lock_path" => lock_path,
    "lock" => lock,
    "approval" => approval,
    "approved_at" => approved_at,
    "approved" => valid_approval
  }
end

change_links = {}
change_records.each do |change_id, record|
  predecessor = record.dig("proposal", "supersedes_change_id")
  barrier_id = record.dig("proposal", "supersession_barrier_attestation_id")
  if predecessor.nil?
    errors << "lineage-root Change #{change_id} preallocates an unnecessary supersession barrier" unless barrier_id.nil?
    next
  end

  valid_predecessor = predecessor.to_s.match?(/\ACHG-[0-9]{4}-[0-9]{3}(?:-[A-Za-z0-9-]+)?\z/) && predecessor != change_id
  errors << "successor Change #{change_id} lacks a preallocated CHGSUPAUTH barrier ID" unless barrier_id.to_s.match?(/\ACHGSUPAUTH-[A-Z0-9._-]+\z/)
  errors << "change #{change_id} has an invalid supersedes_change_id" unless valid_predecessor
  errors << "change #{change_id} supersedes an unknown/deleted Change #{predecessor}" unless change_records.key?(predecessor)
  if change_records.key?(predecessor) && !change_records[predecessor]["approved"]
    errors << "change #{change_id} supersedes a predecessor that is not externally approved"
  end
  change_links[change_id] = predecessor if valid_predecessor && change_records.key?(predecessor)
end

change_supersession_cycles(change_links).each do |cycle|
  errors << "Change supersession graph contains a cycle: #{cycle.join(', ')}"
end

barrier_records = {}
change_records.each do |change_id, record|
  predecessor_id = record.dig("proposal", "supersedes_change_id")
  next unless predecessor_id && record["approved"]

  predecessor = change_records[predecessor_id]
  barrier = predecessor && predecessor["approved"] && validate_change_supersession_barrier(
    errors: errors,
    successor_id: change_id,
    successor_record: record,
    predecessor_id: predecessor_id,
    predecessor_record: predecessor,
    verifiers: trusted_verifiers
  )
  if barrier
    record["barrier"] = barrier
    barrier_records[change_id] = barrier
  else
    record["approved"] = false
  end
end

barrier_records.values.group_by { |record| record.dig("document", "ledger", "ledgerId") }.each do |ledger_id, records|
  ordered = records.sort_by { |record| record.dig("document", "ledger", "lineageSequence") }
  sequence_values = ordered.map { |record| record.dig("document", "ledger", "lineageSequence") }
  revision_values = ordered.map { |record| record.dig("document", "ledger", "revision") }
  errors << "supersession barrier ledger #{ledger_id} reuses a lineage sequence" unless sequence_values.uniq.length == sequence_values.length
  errors << "supersession barrier ledger #{ledger_id} reuses a ledger revision" unless revision_values.uniq.length == revision_values.length
  ordered.each_cons(2) do |previous, following|
    monotonic = following.dig("document", "ledger", "revision") > previous.dig("document", "ledger", "revision") &&
                following["closed_at"] > previous["closed_at"]
    errors << "supersession barrier ledger #{ledger_id} is not monotonic" unless monotonic
  end
end

approved_change_records = change_records.select { |_change_id, record| record["approved"] }
approved_successors_by_predecessor = Hash.new { |hash, key| hash[key] = [] }
approved_change_records.each do |change_id, record|
  predecessor_id = record.dig("proposal", "supersedes_change_id")
  next if predecessor_id.nil?

  predecessor = approved_change_records[predecessor_id]
  if predecessor.nil?
    errors << "approved successor Change #{change_id} does not reference an externally approved predecessor"
  elsif predecessor["approved_at"] >= record["approved_at"]
    errors << "approved successor Change #{change_id} does not postdate predecessor #{predecessor_id}"
  end
  approved_successors_by_predecessor[predecessor_id] << record.merge("change_id" => change_id)
end
approved_successors_by_predecessor.each do |predecessor_id, successors|
  next if successors.length <= 1

  errors << "approved Change #{predecessor_id} has multiple approved successors: #{successors.map { |entry| entry['change_id'] }.sort.join(', ')}"
end
effective_change_successors = approved_successors_by_predecessor.transform_values do |successors|
  successors.min_by { |entry| entry["approved_at"] }
end

platform_profiles = {}
platform_profile_metadata = {}
Dir.glob(ROOT.join("openspec/platforms/*/profile.md")).sort.each do |path|
  text = File.read(path)
  profile_id = text[/^> ID：([^\s]+)\s*$/, 1]
  version = text[/^> Version：([^\s]+)\s*$/, 1]
  errors << "duplicate platform profile ID #{profile_id}" if profile_id && platform_profiles.key?(profile_id)
  if profile_id
    platform_profiles[profile_id] = path
    platform_profile_metadata[profile_id] = { "id" => profile_id, "version" => version, "path" => relative(path) }
  end
end
integration_profiles = {}
integration_profile_metadata = {}
Dir.glob(ROOT.join("openspec/integrations/**/profile.md")).sort.each do |path|
  text = File.read(path)
  profile_id = text[/^> ID：([^\s]+)\s*$/, 1]
  version = text[/^> Version：([^\s]+)\s*$/, 1]
  errors << "duplicate integration profile ID #{profile_id}" if profile_id && integration_profiles.key?(profile_id)
  if profile_id
    integration_profiles[profile_id] = path
    integration_profile_metadata[profile_id] = { "id" => profile_id, "version" => version, "path" => relative(path) }
  end
end

hardware_evidence_ids = {}
hardware_evidence_paths = {}
hardware_evaluation_time = nil
unless ENV["ARKDECK_EVALUATION_TIME"].to_s.empty?
  begin
    evaluation_text = ENV.fetch("ARKDECK_EVALUATION_TIME")
    raise Date::Error unless evaluation_text.match?(RFC3339_DATE_TIME)
    hardware_evaluation_time = DateTime.iso8601(evaluation_text)
  rescue Date::Error
    errors << "ARKDECK_EVALUATION_TIME is not a valid RFC 3339 timestamp"
  end
end
Dir.glob(ROOT.join("openspec/verification/hardware-evidence/*.json")).sort.each do |path|
  record = JSON.parse(File.read(path))
  evidence_id = record["evidenceId"]
  errors << "hardware evidence filename/id mismatch: #{relative(path)}" unless File.basename(path, ".json") == evidence_id
  errors << "duplicate hardware evidence #{evidence_id}" if hardware_evidence_ids.key?(evidence_id)
  hardware_evidence_ids[evidence_id] = true
  hardware_evidence_paths[evidence_id] = Pathname.new(path)
  approval = approvals[record["approvalId"]]
  valid_approval = approval &&
                   approval["subjectType"] == "hardwareEvidence" &&
                   approval["subjectId"] == evidence_id &&
                   approval["subjectRevision"] == 1 &&
                   approval["subjectSha256"] == Digest::SHA256.file(path).hexdigest &&
                   approval["baseRevision"] == record["implementationRevision"] && git_commit?(record["implementationRevision"]) &&
                   approval["decision"] == "approved" &&
                   externally_verified?(approval_paths[approval["approvalId"]], path, approval, trusted_verifiers)
  approval_after_observation = false
  historical_window_valid = false
  hardware_platform_entry = platform_lock && Array(platform_lock["profiles"]).find { |entry| entry["platform"] == record["platform"] }
  case_manifest_binding_valid = hardware_platform_entry &&
                                record["platformCaseManifestSha256"] == hardware_platform_entry["case_manifest_sha256"]
  begin
    observed_at = DateTime.iso8601(record.fetch("observedAt"))
    valid_until = DateTime.iso8601(record.fetch("validUntil"))
    approved_at = DateTime.iso8601(approval.fetch("approvedAt")) if approval
    historical_window_valid = valid_until > observed_at && approval && approved_at >= observed_at && approved_at <= valid_until
    valid_window = hardware_evaluation_time && observed_at <= hardware_evaluation_time && hardware_evaluation_time <= valid_until
    approval_after_observation = approval && approved_at >= observed_at && hardware_evaluation_time && approved_at <= hardware_evaluation_time
  rescue KeyError, Date::Error, NoMethodError
    valid_window = false
    approval_after_observation = false
  end
  if record["status"] == "verified" && valid_approval && historical_window_valid
    approved_hardware[evidence_id] = record
  elsif record["status"] == "verified"
    errors << "verified hardware evidence is not immutably approved or has an invalid observation/approval window: #{evidence_id}"
  end
  if approved_hardware.key?(evidence_id) && valid_window && approval_after_observation && case_manifest_binding_valid
    supported_cell_ids = Array(platform_support_definitions[record["platform"]]).map { |cell| cell["id"] }
    if supported_cell_ids.include?(record["hostSupportCellId"])
      verified_hardware[evidence_id] = record
    end
  end
end

change_scopes = {}
Dir.glob(ROOT.join("openspec/changes/chg-*/scope.yaml")).sort.each do |path|
  scope_path = Pathname.new(path)
  scope = YAML.safe_load(scope_path.read, aliases: true) || {}
  expected_fields = %w[acceptance change_id requirements revision schema]
  errors << "change scope #{relative(scope_path)} has an invalid shape" unless scope.keys.map(&:to_s).sort == expected_fields
  expected_change_id = scope_path.parent.basename.to_s.sub(/\Achg-/, "CHG-")
  errors << "change scope #{relative(scope_path)} identity mismatch" unless scope["schema"] == "arkdeck-change-scope-1" && scope["change_id"].to_s.downcase == expected_change_id.downcase
  proposal_path = scope_path.parent.join("proposal.md")
  proposal = proposal_path.file? ? markdown_frontmatter(proposal_path) : {}
  errors << "change scope #{relative(scope_path)} revision mismatch or unsupported in-place r2" unless scope["revision"] == 1 && proposal["revision"] == 1
  requirement_scope = Array(scope["requirements"])
  acceptance_scope = Array(scope["acceptance"])
  errors << "change scope #{relative(scope_path)} has empty Requirement/AC sets" if requirement_scope.empty? || acceptance_scope.empty?
  errors << "change scope #{relative(scope_path)} has duplicate Requirement/AC IDs" unless requirement_scope.uniq.length == requirement_scope.length && acceptance_scope.uniq.length == acceptance_scope.length
  requirement_scope.each do |id|
    errors << "change scope #{relative(scope_path)} has unknown Requirement/Port #{id} in its baseline+delta overlay" unless requirement_known_for_change.call(scope["change_id"], id)
  end
  acceptance_scope.each do |id|
    errors << "change scope #{relative(scope_path)} has unknown Acceptance #{id} in its baseline+delta overlay" unless acceptance_known_for_change.call(scope["change_id"], id)
  end
  overlay = behavior_overlays[scope["change_id"]]
  if proposal["schema"] == "arkdeck-behavior"
    if overlay.nil?
      errors << "behavior change scope #{relative(scope_path)} has no valid baseline+delta overlay"
    else
      errors << "behavior change scope #{relative(scope_path)} omits a changed Requirement" unless (overlay["touched_requirements"] - requirement_scope).empty?
      errors << "behavior change scope #{relative(scope_path)} omits a changed Acceptance" unless (overlay["touched_acceptance"] - acceptance_scope).empty?
      verification_text = scope_path.parent.join("verification.md").file? ? scope_path.parent.join("verification.md").read : ""
      acceptance_scope.each do |id|
        errors << "behavior change verification plan omits scoped Acceptance #{id}" unless verification_text.match?(/\b#{Regexp.escape(id)}\b/)
      end
    end
    errors << "behavior change #{scope['change_id']} requires a change-local canonical acceptance registry" unless scope_path.parent.join("acceptance-cases.yaml").file?
    local_acceptance = behavior_case_definitions.fetch(scope["change_id"], {}).keys
  else
    if proposal["schema"] == "arkdeck-platform"
      impact_path = scope_path.parent.join("spec-impact.md")
      exact_scope_marker = impact_path.file? && impact_path.read.match?(/^> Exact affected scope：`scope\.yaml`\s*$/)
      errors << "platform change #{scope['change_id']} spec-impact does not declare scope.yaml as its single exact affected set" unless exact_scope_marker
      errors << "platform change #{scope['change_id']} requires a canonical acceptance registry (empty cases are allowed)" unless scope_path.parent.join("acceptance-cases.yaml").file?
    end
    local_acceptance = platform_acceptance.select { |_id, metadata| metadata["change_id"] == scope["change_id"] }.keys
  end
  errors << "change scope #{relative(scope_path)} omits a change-local Acceptance" unless (local_acceptance - acceptance_scope).empty?
  errors << "duplicate change scope #{scope['change_id']}" if change_scopes.key?(scope["change_id"])
  change_scopes[scope["change_id"]] = scope
end

task_schema = JSON.parse(ROOT.join("openspec/contracts/task-packet.schema.json").read)
task_packets = {}
task_packet_paths = {}
Dir.glob(ROOT.join("openspec/changes/**/task-packets/*.json")).sort.each do |path|
  next if archived_change_path?(path)

  packet = JSON.parse(File.read(path))
  task_id = packet["taskId"]
  missing = task_schema.fetch("required") - packet.keys
  extra = packet.keys - task_schema.fetch("properties").keys
  errors << "task packet #{relative(path)} missing #{missing.join(', ')}" unless missing.empty?
  errors << "task packet #{relative(path)} has unknown fields #{extra.join(', ')}" unless extra.empty?
  errors << "task packet filename/id mismatch: #{relative(path)}" unless File.basename(path, ".json") == task_id
  errors << "duplicate Task packet #{task_id}" if task_packets.key?(task_id)
  task_packets[task_id] = packet
  task_packet_paths[task_id] = path

  mutable_fields = %w[claim attempt owner claimedBy run result runtimeStatus]
  present_mutable = mutable_fields & packet.keys
  errors << "immutable Task packet #{task_id} contains runtime fields #{present_mutable.join(', ')}" unless present_mutable.empty?

  packet_acceptance = Array(packet["acceptanceRefs"])
  verification_acceptance = Array(packet["verification"]).map { |item| item["acceptanceId"] }
  errors << "Task #{task_id} verification does not exactly cover acceptanceRefs" unless packet_acceptance.sort == verification_acceptance.sort
  errors << "Task #{task_id} has duplicate acceptanceRefs" unless packet_acceptance.uniq.length == packet_acceptance.length
  test_ids = Array(packet["verification"]).map { |item| item["testId"] }
  errors << "Task #{task_id} has duplicate test IDs" unless test_ids.uniq.length == test_ids.length
  Array(packet["verification"]).each do |item|
    case_definition = case_definition_for_change.call(packet["changeId"], item["acceptanceId"])
    if case_definition
      unless item["testId"] == case_definition["test_id"] &&
             item["method"] == case_definition["method"] &&
             item["minimumEvidence"] == case_definition["minimum_evidence"]
        errors << "Task #{task_id} changes canonical Test ID/method/evidence for #{item['acceptanceId']}"
      end
    else
      errors << "Task #{task_id} has no canonical acceptance case for #{item['acceptanceId']}"
    end
  end
  packet_acceptance.each do |id|
    unless acceptance_known_for_change.call(packet["changeId"], id)
      errors << "Task #{task_id} references unknown acceptance #{id}"
    end
  end
  packet_acceptance.each do |id|
    platform_case = platform_acceptance[id]
    next unless platform_case

    errors << "Task #{task_id} uses a platform acceptance case from another platform" unless platform_case["platform"] == packet["platform"]
    errors << "Task #{task_id} uses a platform acceptance case from another change" unless platform_case["change_id"] == packet["changeId"]
  end

  Array(packet["requirementRefs"]).each do |id|
    errors << "Task #{task_id} references unknown requirement/port #{id} in its baseline+delta overlay" unless requirement_known_for_change.call(packet["changeId"], id)
  end

  %w[allowedPaths forbiddenPaths deliverables verification stopConditions].each do |field|
    errors << "Task #{task_id} has empty #{field}" if Array(packet[field]).empty?
  end
  %w[allowedPaths forbiddenPaths].each do |field|
    Array(packet[field]).each do |value|
      errors << "Task #{task_id} #{field} is not a repository path pattern: #{value}" if value.to_s.empty? || value.start_with?("/") || value.match?(/\s/)
    end
  end
  errors << "Task #{task_id} must pin at least one integration profile" if Array(packet["integrationProfiles"]).empty?
  if packet["hardwareRequirement"] == "required" && !Array(packet["verification"]).any? { |item| item["minimumEvidence"] == "realHardware" }
    errors << "Task #{task_id} requires hardware but has no realHardware acceptance case"
  end
  if packet["risk"] == "destructive" && packet["hardwareRequirement"] == "required" && packet["executionEnvironment"] != "controlledHardwareLab"
    errors << "Task #{task_id} may execute destructive hardware work outside a controlled lab"
  end
  runtime_capabilities = Array(packet["runtimeCapabilities"])
  resource_kinds = Array(packet["exclusiveResources"]).map do |resource|
    match = resource.match(/\Aarkdeck-resource:([a-z-]+):(?:[A-Za-z0-9._~-]|%[0-9A-F]{2})+\z/)
    match && match[1]
  end.compact
  errors << "Task #{task_id} has non-canonical exclusive resource identity" unless resource_kinds.length == Array(packet["exclusiveResources"]).length
  errors << "Task #{task_id} device-network capability lacks an hdc-server resource" if runtime_capabilities.include?("deviceNetworkAccess") && !resource_kinds.include?("hdc-server")
  if (runtime_capabilities & %w[realDeviceRead realDeviceMutation destructiveDeviceMutation]).any? && !resource_kinds.include?("device-binding")
    errors << "Task #{task_id} real-device capability lacks a device-binding resource"
  end
  errors << "Task #{task_id} external-filesystem capability lacks a host-volume resource" if runtime_capabilities.include?("externalFilesystemWrite") && !resource_kinds.include?("host-volume")
  if packet["executionEnvironment"] == "standardAgent" && !(runtime_capabilities & %w[destructiveDeviceMutation hostPrivilegeElevation]).empty?
    errors << "Task #{task_id} grants a standard Agent destructive-device or host-elevation capability"
  end
  if (runtime_capabilities & %w[realDeviceRead realDeviceMutation destructiveDeviceMutation]).any? && packet["hardwareRequirement"] == "none"
    errors << "Task #{task_id} grants real-device capability without declaring hardware"
  end
  if packet["executionEnvironment"] == "controlledHardwareLab" && (runtime_capabilities & %w[realDeviceRead realDeviceMutation destructiveDeviceMutation]).empty?
    errors << "Task #{task_id} declares a controlled hardware lab without a real-device capability"
  end
  if runtime_capabilities.include?("destructiveDeviceMutation") &&
     (packet["executionEnvironment"] != "controlledHardwareLab" || packet["risk"] != "destructive" || packet["hardwareRequirement"] != "required")
    errors << "Task #{task_id} destructive-device capability lacks controlled-lab/destructive/required-hardware gates"
  end
  if packet_acceptance.include?("AC-FLASH-014-01") && packet["executionEnvironment"] != "controlledHardwareLab"
    errors << "Task #{task_id} cannot produce real Flash support evidence outside a controlled lab"
  end
  if packet_acceptance.include?("AC-FLASH-014-01") &&
     (packet["risk"] != "destructive" || packet["hardwareRequirement"] != "required" || !runtime_capabilities.include?("destructiveDeviceMutation"))
    errors << "Task #{task_id} real Flash evidence lacks destructive risk/capability/required-hardware gates"
  end

  platform_pin = packet["platformProfile"] || {}
  if platform_pin["sha256"]
    live_path = platform_profiles[platform_pin["id"]]
    metadata = platform_profile_metadata[platform_pin["id"]]
    unless live_path && metadata && platform_pin["version"] == metadata["version"] && platform_pin["sha256"] == Digest::SHA256.file(live_path).hexdigest
      errors << "Task #{task_id} draft/current platform pin is stale"
    end
  end
  locked_platform_binding = platform_lock && Array(platform_lock["profiles"]).find { |entry| entry["id"] == platform_pin["id"] }
  if locked_platform_binding && packet["platform"] != locked_platform_binding["platform"]
    errors << "Task #{task_id} platform does not match its platform profile"
  end
  Array(packet["integrationProfiles"]).each do |pin|
    next unless pin["sha256"]

    live_path = integration_profiles[pin["id"]]
    metadata = integration_profile_metadata[pin["id"]]
    unless live_path && metadata && pin["version"] == metadata["version"] && pin["sha256"] == Digest::SHA256.file(live_path).hexdigest
      errors << "Task #{task_id} draft/current integration pin #{pin['id']} is stale"
    end
  end
  conformance_pin = packet["conformanceSuite"] || {}
  if conformance_pin["sha256"] && (conformance_pin["id"] != conformance["suite"] || conformance_pin["sha256"] != Digest::SHA256.file(conformance_path).hexdigest)
    errors << "Task #{task_id} draft/current conformance pin is stale"
  end
  core_pin = packet["coreBaseline"] || {}
  if core_pin["sha256"] && core_pin["sha256"] != Digest::SHA256.file(baseline_path).hexdigest
    errors << "Task #{task_id} draft/current Core baseline pin is stale"
  end

  next unless packet["status"] == "ready"

  errors << "ready Task #{task_id} is forbidden while externally rooted trust gate is closed" unless external_trust_root_valid && trust_policy["status"] == "accepted" && trust_policy["execution_gate"] == "open" && !trusted_verifiers.empty?
  errors << "ready Task #{task_id} requires accepted/open Core baseline" unless baseline && baseline["status"] == "accepted" && baseline.dig("ratification", "execution_gate") == "open"
  errors << "ready Task #{task_id} requires accepted/open Integration lock" unless integration_lock && integration_lock["status"] == "accepted" && integration_lock["execution_gate"] == "open"
  errors << "ready Task #{task_id} requires accepted/open conformance suite" unless conformance && conformance["status"] == "accepted" && conformance["execution_gate"] == "open"
  errors << "ready Task #{task_id} requires accepted/open platform lock" unless platform_lock && platform_lock["status"] == "accepted" && platform_lock["execution_gate"] == "open"

  change_root = Pathname.new(path).parent.parent
  %w[proposal.md scope.yaml design.md verification.md review.md ready-review.md tasks.md].each do |name|
    errors << "ready Task #{task_id} change is missing #{name}" unless change_root.join(name).file?
  end
  proposal_path = change_root.join("proposal.md")
  proposal = proposal_path.file? ? markdown_frontmatter(proposal_path) : {}
  errors << "ready Task #{task_id} proposal source was mutated or revision drifted" unless proposal["status"] == "proposed" && proposal["revision"] == packet["changeRevision"]
  errors << "ready Task #{task_id} proposal identity/Core pin mismatch" unless proposal["id"] == packet["changeId"] && proposal["core_baseline"] == baseline["baseline"]
  change_level = proposal["core_change_level"]
  errors << "ready Task #{task_id} has invalid core_change_level" unless %w[none patch minor major].include?(change_level)
  if proposal["schema"] == "arkdeck-behavior" && !%w[minor major].include?(change_level)
    errors << "ready Task #{task_id} behavior change must be MINOR or MAJOR in V1"
  end
  errors << "ready Task #{task_id} class core cannot declare no Core change" if proposal["class"] == "core" && change_level == "none"
  if %w[minor major].include?(change_level)
    validate_platform_revalidation(
      errors: errors,
      subject: "ready Task #{task_id} Core change",
      matrix: proposal["platform_revalidation"],
      declared_platforms: declared_platforms,
      current_delivery_platforms: current_delivery_platforms
    )
  end
  case proposal["schema"]
  when "arkdeck-platform"
    errors << "ready Task #{task_id} platform change requires spec-impact.md" unless change_root.join("spec-impact.md").file?
    errors << "ready Task #{task_id} platform change must not carry behavior delta specs" unless Dir.glob(change_root.join("specs/**/*.md").to_s).empty?
  when "arkdeck-behavior"
    errors << "ready Task #{task_id} behavior change requires at least one delta spec" if Dir.glob(change_root.join("specs/**/*.md").to_s).empty?
    errors << "ready Task #{task_id} behavior change must not replace delta with spec-impact.md" if change_root.join("spec-impact.md").file?
  else
    errors << "ready Task #{task_id} proposal has unknown change schema"
  end
  review_status = change_root.join("review.md").file? ? change_root.join("review.md").read[/^> Status：([^\s]+)\s*$/, 1] : nil
  errors << "ready Task #{task_id} requires passed pre-task review" unless review_status == "passed"
  ready_review_path = change_root.join("ready-review.md")
  ready_review_status = ready_review_path.file? ? ready_review_path.read[/^> Status：([^\s]+)\s*$/, 1] : nil
  errors << "ready Task #{task_id} requires passed ready-review" unless ready_review_status == "passed"
  change_lock_path = change_root.join("change-lock.yaml")
  if !change_lock_path.file?
    errors << "ready Task #{task_id} requires immutable change-lock.yaml"
  else
    change_lock = YAML.safe_load(change_lock_path.read, aliases: true) || {}
    errors << "ready Task #{task_id} change lock is not approved" unless change_lock["status"] == "approved" && change_lock["change_id"] == packet["changeId"] && change_lock["revision"] == packet["changeRevision"]
    lock_entries = Array(change_lock["files"])
    lock_paths = lock_entries.map { |entry| entry["path"] }
    expected_lock_paths = expected_change_input_paths(change_root)
    errors << "ready Task #{task_id} change-lock has duplicate paths" unless lock_paths.uniq.length == lock_paths.length
    errors << "ready Task #{task_id} change-lock is not the exact change input set" unless lock_paths.sort == expected_lock_paths
    lock_entries.each do |entry|
      locked_path = ROOT.join(entry["path"].to_s)
      if !locked_path.file? || Digest::SHA256.file(locked_path).hexdigest != entry["sha256"]
        errors << "ready Task #{task_id} change-lock input drift: #{entry['path']}"
      end
    end
    change_approval = approvals[change_lock["approval_id"]]
    valid_change_approval = change_approval &&
                            change_approval["subjectType"] == "change" &&
                            change_approval["subjectId"] == packet["changeId"] &&
                            change_approval["subjectRevision"] == packet["changeRevision"] &&
                            change_approval["subjectSha256"] == Digest::SHA256.file(change_lock_path).hexdigest &&
                            change_approval["baseRevision"] == packet["baseRevision"] &&
                            change_approval["decision"] == "approved" &&
                            externally_verified?(approval_paths[change_approval["approvalId"]], change_lock_path, change_approval, trusted_verifiers)
    errors << "ready Task #{task_id} change approval is not externally verified" unless valid_change_approval
  end

  pins = [packet.dig("coreBaseline", "sha256"), packet.dig("platformProfile", "sha256"), packet.dig("conformanceSuite", "sha256")] +
         Array(packet["integrationProfiles"]).map { |item| item["sha256"] }
  errors << "ready Task #{task_id} has unresolved hash pins" unless pins.all? { |value| value.to_s.match?(/\A[a-f0-9]{64}\z/) }
  errors << "ready Task #{task_id} has no base revision" if packet["baseRevision"].to_s.empty?
  errors << "ready Task #{task_id} base revision is not a real Git commit" unless git_commit?(packet["baseRevision"])
  if baseline_path.file?
    errors << "ready Task #{task_id} Core baseline hash drift" unless packet.dig("coreBaseline", "sha256") == Digest::SHA256.file(baseline_path).hexdigest
    expected_baseline_id = "#{packet.dig('coreBaseline', 'id')}-#{packet.dig('coreBaseline', 'version')}"
    errors << "ready Task #{task_id} Core baseline identity drift" unless expected_baseline_id == baseline["baseline"]
  end
  profile_path = platform_profiles[packet.dig("platformProfile", "id")]
  profile_metadata = platform_profile_metadata[packet.dig("platformProfile", "id")]
  locked_platform = platform_lock && Array(platform_lock["profiles"]).find { |entry| entry["id"] == packet.dig("platformProfile", "id") }
  if profile_path.nil?
    errors << "ready Task #{task_id} references unknown platform profile"
  elsif packet.dig("platformProfile", "sha256") != Digest::SHA256.file(profile_path).hexdigest ||
        packet.dig("platformProfile", "version") != profile_metadata["version"]
    errors << "ready Task #{task_id} platform profile hash drift"
  end
  unless locked_platform &&
         locked_platform["version"] == packet.dig("platformProfile", "version") &&
         locked_platform["profile_sha256"] == packet.dig("platformProfile", "sha256")
    errors << "ready Task #{task_id} platform profile is not in the accepted lock"
  end
  Array(packet["integrationProfiles"]).each do |pin|
    profile_path = integration_profiles[pin["id"]]
    metadata = integration_profile_metadata[pin["id"]]
    locked_profile = integration_locked_profiles[pin["id"]]
    if profile_path.nil?
      errors << "ready Task #{task_id} references unknown integration profile #{pin['id']}"
    elsif pin["sha256"] != Digest::SHA256.file(profile_path).hexdigest || pin["version"] != metadata["version"]
      errors << "ready Task #{task_id} integration profile hash drift"
    end
    unless locked_profile && locked_profile["version"] == pin["version"] && locked_profile["sha256"] == pin["sha256"]
      errors << "ready Task #{task_id} integration profile #{pin['id']} is not in the accepted lock"
    end
  end
  errors << "ready Task #{task_id} conformance identity/hash drift" unless packet.dig("conformanceSuite", "id") == conformance["suite"] && packet.dig("conformanceSuite", "sha256") == Digest::SHA256.file(conformance_path).hexdigest
  Array(packet["verification"]).each do |item|
    next unless item["minimumEvidence"] == "parserGolden"

    fixture_refs = Array(item["fixtureRefs"])
    errors << "ready Task #{task_id} parser case #{item['acceptanceId']} has no pinned fixture" if fixture_refs.empty?
    errors << "ready Task #{task_id} parser case #{item['acceptanceId']} references an unpinned fixture" unless (fixture_refs - conformance_fixture_ids).empty?
  end
  approval = approvals[packet["approvalId"]]
  if approval.nil?
    errors << "ready Task #{task_id} has no matching approval attestation"
  else
    digest = Digest::SHA256.file(path).hexdigest
    errors << "Task #{task_id} approval is not for this packet" unless approval["subjectType"] == "taskPacket" && approval["subjectId"] == task_id && approval["subjectRevision"] == packet["revision"]
    errors << "Task #{task_id} approval hash mismatch" unless approval["subjectSha256"] == digest
    errors << "Task #{task_id} approval base revision mismatch" unless approval["baseRevision"] == packet["baseRevision"]
    errors << "Task #{task_id} approval decision is not approved" unless approval["decision"] == "approved"
    unless externally_verified?(approval_paths[approval["approvalId"]], path, approval, trusted_verifiers)
      errors << "Task #{task_id} approval is not externally verified"
    end
  end
end

task_packets.each do |task_id, packet|
  Array(packet["dependsOn"]).each do |dependency|
    errors << "Task #{task_id} has unknown dependency #{dependency}" unless task_packets.key?(dependency)
  end
end

task_packets.values.group_by { |packet| packet["changeId"] }.each do |change_id, packets|
  scope = change_scopes[change_id]
  if scope.nil?
    errors << "change #{change_id} has Task packets but no immutable scope.yaml"
    next
  end
  task_requirements = packets.flat_map { |packet| Array(packet["requirementRefs"]) }.uniq.sort
  task_acceptance = packets.flat_map { |packet| Array(packet["acceptanceRefs"]) }.uniq.sort
  errors << "change #{change_id} Task Requirement union differs from approved scope" unless task_requirements == Array(scope["requirements"]).sort
  errors << "change #{change_id} Task Acceptance union differs from approved scope" unless task_acceptance == Array(scope["acceptance"]).sort
end

Dir.glob(ROOT.join("openspec/changes/**/tasks.md")).sort.each do |path|
  next if archived_change_path?(path)

  indexed = File.read(path).scan(/\b(TASK-[A-Z0-9-]+)\b/).flatten.uniq
  local_packets = Dir.glob(File.join(File.dirname(path), "task-packets/*.json")).map { |packet_path| File.basename(packet_path, ".json") }
  errors << "Task index #{relative(path)} differs from packet files" unless indexed.sort == local_packets.sort
end

claim_schema = JSON.parse(ROOT.join("openspec/contracts/task-claim.schema.json").read)
claim_owner_schema = JSON.parse(ROOT.join("openspec/contracts/claim-owner-attestation.schema.json").read)
resource_identity_schema = JSON.parse(ROOT.join("openspec/contracts/resource-identity-attestation.schema.json").read)
lab_authorization_schema = JSON.parse(ROOT.join("openspec/contracts/lab-execution-authorization.schema.json").read)
lab_plan_schema = JSON.parse(ROOT.join("openspec/contracts/lab-execution-plan.schema.json").read)
claims = {}
claim_paths_by_id = {}
claim_keys = {}
claim_intervals = []
claim_owner_attestations = {}
lab_authorizations = {}
lab_plans = {}
claim_attestation_ids = {}
resource_attestation_ids = {}
lab_authorization_ids = {}
lab_plan_ids = {}
Dir.glob(ROOT.join("openspec/changes/**/evidence/runs/**/claim.json")).sort.each do |path|
  next if archived_change_path?(path)

  claim = JSON.parse(File.read(path))
  missing = claim_schema.fetch("required") - claim.keys
  extra = claim.keys - claim_schema.fetch("properties").keys
  errors << "claim #{relative(path)} missing #{missing.join(', ')}" unless missing.empty?
  errors << "claim #{relative(path)} has unknown fields #{extra.join(', ')}" unless extra.empty?
  task = task_packets[claim["taskId"]]
  if task.nil?
    errors << "claim #{relative(path)} references unknown Task"
  else
    packet_path = task_packet_paths.fetch(claim["taskId"])
    errors << "claim #{relative(path)} Task packet hash mismatch" unless claim["taskPacketSha256"] == Digest::SHA256.file(packet_path).hexdigest
    errors << "claim #{relative(path)} task revision mismatch" unless claim["taskRevision"] == task["revision"]
    errors << "claim #{relative(path)} approval mismatch" unless claim["approvalId"] == task["approvalId"]
    errors << "claim #{relative(path)} targets a Task that is not ready" unless task["status"] == "ready"
    errors << "claim #{relative(path)} change mismatch" unless claim["changeId"] == task["changeId"] && claim["changeRevision"] == task["changeRevision"]
    expected_core = "#{task.dig('coreBaseline', 'id')}-#{task.dig('coreBaseline', 'version')}"
    errors << "claim #{relative(path)} Core baseline mismatch" unless claim["coreBaseline"] == expected_core && claim["coreBaselineSha256"] == task.dig("coreBaseline", "sha256")
    errors << "claim #{relative(path)} platform profile mismatch" unless claim["platformProfile"] == task["platformProfile"]
    errors << "claim #{relative(path)} integration profiles mismatch" unless Array(claim["integrationProfiles"]).sort_by { |item| item["id"] } == Array(task["integrationProfiles"]).sort_by { |item| item["id"] }
    errors << "claim #{relative(path)} conformance suite mismatch" unless claim["conformanceSuite"] == task["conformanceSuite"]
    errors << "claim #{relative(path)} platform/base revision mismatch" unless claim["platform"] == task["platform"] && claim["baseRevision"] == task["baseRevision"]
    errors << "claim #{relative(path)} exclusive resources mismatch" unless Array(claim["exclusiveResources"]).sort == Array(task["exclusiveResources"]).sort
    if task["executionEnvironment"] == "controlledHardwareLab" && claim["claimantKind"] != "humanOperator"
      errors << "claim #{relative(path)} controlled hardware-lab Task is not held by a human operator"
    end
  end
  begin
    claimed_at = DateTime.iso8601(claim.fetch("claimedAt"))
    expires_at = DateTime.iso8601(claim.fetch("leaseExpiresAt"))
    errors << "claim #{relative(path)} lease is not after claim time" unless expires_at > claimed_at
    errors << "claim #{relative(path)} lease exceeds the 24-hour V1 bound" if (expires_at - claimed_at) * 86_400 > 86_400
    if (successor = effective_change_successors[claim["changeId"]]) && !claim_precedes_successor?(claimed_at: claimed_at, successor_approved_at: successor["approved_at"])
      errors << "claim #{relative(path)} was issued after Change #{claim['changeId']} was superseded by #{successor['change_id']}"
    end
    change_lock_approval_id = nil
    if task && (packet_source = task_packet_paths[task["taskId"]])
      task_change_lock = Pathname.new(packet_source).parent.parent.join("change-lock.yaml")
      if task_change_lock.file?
        task_change_lock_doc = YAML.safe_load(task_change_lock.read, aliases: true) || {}
        change_lock_approval_id = task_change_lock_doc["approval_id"]
      end
    end
    prerequisite_approvals = {
      "Task packet" => task && task["approvalId"],
      "change" => change_lock_approval_id,
      "Core baseline" => baseline && baseline.dig("ratification", "approval_ref"),
      "Integration lock" => integration_lock && integration_lock.dig("ratification", "approval_ref"),
      "Platform lock" => platform_lock && platform_lock.dig("ratification", "approval_ref"),
      "Core conformance suite" => conformance && conformance.dig("ratification", "approval_ref"),
      "trust policy" => trust_policy.dig("ratification", "approval_ref")
    }
    prerequisite_approvals.each do |label, approval_id|
      prerequisite = approvals[approval_id]
      if prerequisite.nil?
        errors << "claim #{relative(path)} lacks its #{label} prerequisite approval"
        next
      end
      begin
        approved_at = DateTime.iso8601(prerequisite.fetch("approvedAt"))
        errors << "claim #{relative(path)} predates its #{label} approval" unless approved_at <= claimed_at
      rescue KeyError, Date::Error
        errors << "claim #{relative(path)} has an invalid #{label} approval timestamp"
      end
    end
    claim_intervals << [claim["claimId"], claim["taskId"], claimed_at, expires_at, Array(claim["exclusiveResources"])]
  rescue KeyError, Date::Error
    errors << "claim #{relative(path)} has invalid timestamps"
  end
  errors << "claim #{relative(path)} is not immutable claimed state" unless claim["status"] == "claimed"
  errors << "duplicate claim ID #{claim['claimId']}" if claims.key?(claim["claimId"])
  claim_key = [claim["taskId"], claim["attempt"]]
  errors << "duplicate claim for #{claim_key.join('/')}" if claim_keys.key?(claim_key)
  claim_keys[claim_key] = claim["claimId"]
  claims[claim["claimId"]] = claim
  claim_paths_by_id[claim["claimId"]] = Pathname.new(path)

  owner_path = Pathname.new(path).parent.join("claim-owner-attestation.json")
  if !owner_path.file?
    errors << "claim #{relative(path)} has no protected owner attestation"
  else
    owner = JSON.parse(owner_path.read)
    owner_missing = claim_owner_schema.fetch("required") - owner.keys
    owner_extra = owner.keys - claim_owner_schema.fetch("properties").keys
    errors << "claim owner attestation #{relative(owner_path)} missing #{owner_missing.join(', ')}" unless owner_missing.empty?
    errors << "claim owner attestation #{relative(owner_path)} has unknown fields #{owner_extra.join(', ')}" unless owner_extra.empty?
    errors << "duplicate claim owner attestation ID #{owner['attestationId']}" if claim_attestation_ids.key?(owner["attestationId"])
    claim_attestation_ids[owner["attestationId"]] = relative(owner_path)
    valid_owner = owner["subjectType"] == "taskClaim" &&
                  owner["claimId"] == claim["claimId"] &&
                  owner["claimSha256"] == Digest::SHA256.file(path).hexdigest &&
                  owner["taskId"] == claim["taskId"] &&
                  owner["attempt"] == claim["attempt"] &&
                  owner["claimantKind"] == claim["claimantKind"] &&
                  owner["claimedBy"] == claim["claimedBy"] &&
                  owner["claimedAt"] == claim["claimedAt"] &&
                  owner["leaseExpiresAt"] == claim["leaseExpiresAt"] &&
                  externally_verified?(owner_path, path, owner, trusted_verifiers)
    errors << "claim #{relative(path)} owner attestation is not exact or externally verified" unless valid_owner
    claim_owner_attestations[claim["claimId"]] = owner if valid_owner
  end

  resource_path = Pathname.new(path).parent.join("resource-identity-attestation.json")
  core_resource_pattern = /\Aarkdeck-resource:(?:hdc-server|device-binding|host-volume):[a-f0-9]{64}\z/
  claimed_core_resources = Array(claim["exclusiveResources"]).select { |resource| resource.match?(core_resource_pattern) }.sort
  if claimed_core_resources.empty?
    errors << "claim #{relative(path)} carries an unnecessary resource identity attestation" if resource_path.file?
  elsif !resource_path.file?
    errors << "claim #{relative(path)} has no protected canonical resource identity attestation"
  else
    resource_attestation = JSON.parse(resource_path.read)
    resource_missing = resource_identity_schema.fetch("required") - resource_attestation.keys
    resource_extra = resource_attestation.keys - resource_identity_schema.fetch("properties").keys
    errors << "resource identity attestation #{relative(resource_path)} missing #{resource_missing.join(', ')}" unless resource_missing.empty?
    errors << "resource identity attestation #{relative(resource_path)} has unknown fields #{resource_extra.join(', ')}" unless resource_extra.empty?
    errors << "duplicate resource identity attestation ID #{resource_attestation['attestationId']}" if resource_attestation_ids.key?(resource_attestation["attestationId"])
    resource_attestation_ids[resource_attestation["attestationId"]] = relative(resource_path)
    resources = Array(resource_attestation["resources"])
    attested_urns = resources.map { |resource| resource["resourceUrn"] }
    canonical_resources = resources.all? do |resource|
      expected = case resource["kind"]
                 when "hdc-server"
                   Digest::SHA256.hexdigest(["arkdeck-hdc-server-v1", resource["endpoint"], resource["generation"]].join("\0"))
                 when "device-binding"
                   Digest::SHA256.hexdigest(["arkdeck-device-binding-v1", resource["deviceIdentity"], resource["bindingRevision"]].join("\0"))
                 when "host-volume"
                   Digest::SHA256.hexdigest(["arkdeck-host-volume-v1", resource["volumeIdentity"]].join("\0"))
                 end
      expected && resource["resourceUrn"] == "arkdeck-resource:#{resource['kind']}:#{expected}"
    end
    valid_resources = resource_attestation["subjectType"] == "resourceIdentitySet" &&
                      resource_attestation["claimId"] == claim["claimId"] &&
                      resource_attestation["claimSha256"] == Digest::SHA256.file(path).hexdigest &&
                      attested_urns.uniq.length == attested_urns.length &&
                      attested_urns.sort == claimed_core_resources && canonical_resources &&
                      externally_verified?(resource_path, path, resource_attestation, trusted_verifiers)
    errors << "claim #{relative(path)} canonical resource set is not exact or externally verified" unless valid_resources
  end

  lab_path = Pathname.new(path).parent.join("lab-execution-authorization.json")
  if task && task["executionEnvironment"] == "controlledHardwareLab"
    if lab_path.file?
      lab = JSON.parse(lab_path.read)
      lab_missing = lab_authorization_schema.fetch("required") - lab.keys
      lab_extra = lab.keys - lab_authorization_schema.fetch("properties").keys
      errors << "lab authorization #{relative(lab_path)} missing #{lab_missing.join(', ')}" unless lab_missing.empty?
      errors << "lab authorization #{relative(lab_path)} has unknown fields #{lab_extra.join(', ')}" unless lab_extra.empty?
      errors << "duplicate lab authorization ID #{lab['authorizationId']}" if lab_authorization_ids.key?(lab["authorizationId"])
      lab_authorization_ids[lab["authorizationId"]] = relative(lab_path)
      lab_approval = approvals[lab["approvalId"]]
      valid_lab_approval = lab_approval &&
                           lab_approval["subjectType"] == "labExecutionAuthorization" &&
                           lab_approval["subjectId"] == lab["authorizationId"] &&
                           lab_approval["subjectRevision"] == claim["attempt"] &&
                           lab_approval["subjectSha256"] == Digest::SHA256.file(lab_path).hexdigest &&
                           lab_approval["baseRevision"] == claim["baseRevision"] &&
                           lab_approval["decision"] == "approved" &&
                           externally_verified?(approval_paths[lab_approval["approvalId"]], lab_path, lab_approval, trusted_verifiers)
      plan_path = Pathname.new(lab_path).parent.join(lab["planFile"].to_s).expand_path
      plan_contained = lab["planFile"] == "lab-execution-plan.json" && plan_path.parent == Pathname.new(lab_path).parent.expand_path
      plan = plan_contained && plan_path.file? ? JSON.parse(plan_path.read) : {}
      plan_missing = lab_plan_schema.fetch("required") - plan.keys
      plan_extra = plan.keys - lab_plan_schema.fetch("properties").keys
      errors << "lab plan beside #{relative(lab_path)} is missing or has an invalid filename" unless plan_contained && plan_path.file?
      errors << "lab plan beside #{relative(lab_path)} missing #{plan_missing.join(', ')}" unless plan_missing.empty?
      errors << "lab plan beside #{relative(lab_path)} has unknown fields #{plan_extra.join(', ')}" unless plan_extra.empty?
      errors << "duplicate lab plan ID #{plan['planId']}" if lab_plan_ids.key?(plan["planId"])
      lab_plan_ids[plan["planId"]] = relative(plan_path)
      begin
        valid_from = DateTime.iso8601(lab.fetch("validFrom"))
        valid_until = DateTime.iso8601(lab.fetch("validUntil"))
        claimed_at = DateTime.iso8601(claim.fetch("claimedAt"))
        confirmed_at = DateTime.iso8601(lab.dig("physicalTargetConfirmation", "confirmedAt").to_s)
        approved_at = DateTime.iso8601(lab_approval.fetch("approvedAt"))
        valid_window = claimed_at <= confirmed_at && confirmed_at <= approved_at && approved_at <= valid_from && valid_from < valid_until
      rescue KeyError, Date::Error, NoMethodError
        valid_window = false
      end
      executable_plan_steps = plan_executables(plan)
      plan_step_ids = executable_plan_steps.map { |step| step["id"] }
      errors << "lab plan beside #{relative(lab_path)} has duplicate main/compensation Step IDs" unless plan_step_ids.uniq.length == plan_step_ids.length
      plan_kinds = executable_plan_steps.map { |step| step["kind"] }.uniq.sort
      task_capabilities = Array(task["runtimeCapabilities"])
      capability_matches = Array(lab["runtimeCapabilities"]).sort == task_capabilities.sort
      required_device_capabilities = []
      required_device_capabilities << "realDeviceRead" if executable_plan_steps.any? { |step| step["effect"] == "readOnly" && step["bindingRequirement"] == "confirmedDevice" }
      required_device_capabilities << "realDeviceMutation" if executable_plan_steps.any? { |step| step["effect"] == "deviceMutation" }
      required_device_capabilities << "destructiveDeviceMutation" if executable_plan_steps.any? { |step| step["effect"] == "destructive" }
      actual_device_capabilities = task_capabilities & %w[realDeviceRead realDeviceMutation destructiveDeviceMutation]
      capability_matches &&= required_device_capabilities.sort == actual_device_capabilities.sort
      target = plan["target"].is_a?(Hash) ? plan["target"] : {}
      target_resources = target["resourceUrns"].is_a?(Hash) ? target["resourceUrns"] : {}
      expected_hdc_resource = if task_capabilities.include?("deviceNetworkAccess")
                                "arkdeck-resource:hdc-server:#{Digest::SHA256.hexdigest(["arkdeck-hdc-server-v1", target["hdcServerEndpoint"], target["hdcServerGeneration"]].join("\0"))}"
                              end
      expected_device_resource = if actual_device_capabilities.any?
                                   "arkdeck-resource:device-binding:#{Digest::SHA256.hexdigest(["arkdeck-device-binding-v1", target["deviceIdentity"], target["bindingRevision"]].join("\0"))}"
                                 end
      expected_volume_resource = if task_capabilities.include?("externalFilesystemWrite") && !target["hostVolumeIdentity"].to_s.empty?
                                   "arkdeck-resource:host-volume:#{Digest::SHA256.hexdigest(["arkdeck-host-volume-v1", target["hostVolumeIdentity"]].join("\0"))}"
                                 end
      volume_identity_valid = !task_capabilities.include?("externalFilesystemWrite") || !target["hostVolumeIdentity"].to_s.empty?
      resource_matches = volume_identity_valid && target_resources["hdcServer"] == expected_hdc_resource &&
                         target_resources["deviceBinding"] == expected_device_resource &&
                         target_resources["hostVolume"] == expected_volume_resource &&
                         [expected_hdc_resource, expected_device_resource, expected_volume_resource].compact.all? { |urn| Array(claim["exclusiveResources"]).include?(urn) }
      plan_matches = plan["taskId"] == claim["taskId"] && plan["platform"] == claim["platform"] &&
                     plan["target"] == lab["target"] && plan_kinds == Array(lab["authorizedStepKinds"]).sort &&
                     resource_matches && plan_path.file? && Digest::SHA256.file(plan_path).hexdigest == lab["planSha256"]
      owner_file = Pathname.new(path).parent.join("claim-owner-attestation.json")
      valid_lab = lab["claimId"] == claim["claimId"] &&
                  lab["claimSha256"] == Digest::SHA256.file(path).hexdigest &&
                  owner_file.file? && lab["claimOwnerAttestationSha256"] == Digest::SHA256.file(owner_file).hexdigest &&
                  lab["taskId"] == claim["taskId"] &&
                  lab["taskPacketSha256"] == claim["taskPacketSha256"] &&
                  lab["operatorId"] == claim["claimedBy"] &&
                  lab.dig("physicalTargetConfirmation", "confirmedBy") == claim["claimedBy"] &&
                  lab["platform"] == claim["platform"] &&
                  capability_matches && plan_matches &&
                  valid_window && valid_lab_approval
      errors << "controlled hardware-lab claim #{relative(path)} authorization is stale, mismatched or unapproved" unless valid_lab
      lab_authorizations[claim["claimId"]] = lab if valid_lab
      lab_plans[claim["claimId"]] = plan if valid_lab
    end
  elsif lab_path.file?
    errors << "standard claim #{relative(path)} carries an unauthorized lab execution token"
  end
end

run_schema = JSON.parse(ROOT.join("openspec/contracts/task-run.schema.json").read)
run_owner_schema = JSON.parse(ROOT.join("openspec/contracts/run-owner-attestation.schema.json").read)
done_run_times = {}
valid_done_runs = {}
runs_by_claim = {}
run_ids = {}
runs_by_id = {}
run_paths_by_id = {}
real_execution_records_by_run_id = {}
terminal_runs_by_claim = {}
terminal_status_by_claim = {}
superseded_task_ids = {}
task_supersession_by_replacement = {}
run_attestation_ids = {}
Dir.glob(ROOT.join("openspec/changes/**/evidence/runs/**/run.json")).sort.each do |path|
  next if archived_change_path?(path)

  run = JSON.parse(File.read(path))
  missing = run_schema.fetch("required") - run.keys
  extra = run.keys - run_schema.fetch("properties").keys
  errors << "run #{relative(path)} missing #{missing.join(', ')}" unless missing.empty?
  errors << "run #{relative(path)} has unknown fields #{extra.join(', ')}" unless extra.empty?
  errors << "duplicate run ID #{run['runId']}" if run_ids.key?(run["runId"])
  run_ids[run["runId"]] = relative(path)
  runs_by_id[run["runId"]] = run
  run_paths_by_id[run["runId"]] = Pathname.new(path)
  errors << "claim #{run['claimId']} has more than one run record" if runs_by_claim.key?(run["claimId"])
  runs_by_claim[run["claimId"]] = run
  claim = claims[run["claimId"]]
  declared_task = task_packets[run["taskId"]]
  task = claim ? task_packets[claim["taskId"]] : declared_task
  owner_path = Pathname.new(path).parent.join("run-owner-attestation.json")
  valid_run_owner = false
  if !owner_path.file?
    errors << "run #{relative(path)} has no protected owner attestation"
  else
    owner = JSON.parse(owner_path.read)
    owner_missing = run_owner_schema.fetch("required") - owner.keys
    owner_extra = owner.keys - run_owner_schema.fetch("properties").keys
    errors << "run owner attestation #{relative(owner_path)} missing #{owner_missing.join(', ')}" unless owner_missing.empty?
    errors << "run owner attestation #{relative(owner_path)} has unknown fields #{owner_extra.join(', ')}" unless owner_extra.empty?
    errors << "duplicate run owner attestation ID #{owner['attestationId']}" if run_attestation_ids.key?(owner["attestationId"])
    run_attestation_ids[owner["attestationId"]] = relative(owner_path)
    claim_owner = claim_owner_attestations[run["claimId"]]
    valid_run_owner = claim_owner &&
                      owner["claimAttestationId"] == claim_owner["attestationId"] &&
                      owner["claimId"] == run["claimId"] &&
                      owner["runId"] == run["runId"] &&
                      owner["runSha256"] == Digest::SHA256.file(path).hexdigest &&
                      owner["taskId"] == run["taskId"] &&
                      owner["attempt"] == run["attempt"] &&
                      owner["executedBy"] == run["executedBy"] &&
                      owner["finalizedAt"] == run["endedAt"] &&
                      externally_verified?(owner_path, path, owner, trusted_verifiers)
    errors << "run #{relative(path)} owner attestation is not exact or externally verified" unless valid_run_owner
  end
  errors << "run #{relative(path)} has no matching claim" if claim.nil?
  errors << "run #{relative(path)} has no matching Task" if declared_task.nil? || task.nil?
  if claim && task
    errors << "run #{relative(path)} Task does not match its claim" unless run["taskId"] == claim["taskId"]
    errors << "run #{relative(path)} attempt/revision does not match claim" unless run["attempt"] == claim["attempt"] && run["taskRevision"] == claim["taskRevision"]
    packet_path = task_packet_paths[claim["taskId"]]
    errors << "run #{relative(path)} packet hash mismatch" unless packet_path && run["taskPacketSha256"] == claim["taskPacketSha256"] && run["taskPacketSha256"] == Digest::SHA256.file(packet_path).hexdigest
    errors << "run #{relative(path)} Core/change/base mismatch" unless run["coreBaseline"] == claim["coreBaseline"] && run["coreBaselineSha256"] == claim["coreBaselineSha256"] && run["changeId"] == claim["changeId"] && run["changeRevision"] == claim["changeRevision"] && run["baseRevision"] == claim["baseRevision"]
    errors << "run #{relative(path)} profile/conformance mismatch" unless run["platformProfileSha256"] == claim.dig("platformProfile", "sha256") && Array(run["integrationProfileSha256s"]).sort == Array(claim["integrationProfiles"]).map { |item| item["sha256"] }.sort && run["conformanceSuiteSha256"] == claim.dig("conformanceSuite", "sha256")
    errors << "run #{relative(path)} platform mismatch" unless run["platform"] == claim["platform"] && run["platform"] == task["platform"]
    errors << "run #{relative(path)} executedBy differs from claim owner" unless run["executedBy"] == claim["claimedBy"]
    dispatch_count = run["realDeviceDispatchCount"].is_a?(Integer) ? run["realDeviceDispatchCount"] : -1
    execution_records = Array(run["workflowExecutionRecords"])
    execution_ids = execution_records.map { |record| record["id"] }
    errors << "run #{relative(path)} has duplicate workflow execution-record IDs" unless execution_ids.uniq.length == execution_ids.length
    real_execution_records = execution_records.select do |record|
      record["disposition"] == "executed" && record["bindingRequirement"] == "confirmedDevice" && record["effect"] != "hostOnly"
    end
    real_execution_records_by_run_id[run["runId"]] = real_execution_records
    errors << "run #{relative(path)} realDeviceDispatchCount differs from typed execution records" unless dispatch_count == real_execution_records.length
    execution_records.each do |record|
      required_capability = runtime_capability_for_step(record)
      if required_capability && !Array(task["runtimeCapabilities"]).include?(required_capability)
        errors << "run #{relative(path)} executes #{record['id']} without #{required_capability} capability"
      end
      if task["executionEnvironment"] == "standardAgent" && record["disposition"] == "executed" && record["effect"] == "destructive"
        errors << "standard Agent run #{relative(path)} executes forbidden destructive Step #{record['id']}"
      end
    end
    if run["status"] == "done" && execution_records.any? { |record| record["disposition"] == "executed" && (record["semanticResult"] != "succeeded" || record["outcomeCertainty"] != "confirmed") }
      errors << "done run #{relative(path)} contains an unsuccessful/uncertain executed workflow record"
    end
    if task["executionEnvironment"] == "controlledHardwareLab"
      lab = lab_authorizations[claim["claimId"]]
      plan = lab_plans[claim["claimId"]]
      if dispatch_count.positive? && !(lab && run["labAuthorizationId"] == lab["authorizationId"] && run["executionPlanSha256"] == lab["planSha256"])
        errors << "run #{relative(path)} does not bind its approved lab plan/authorization"
      elsif dispatch_count.zero? && !run["labAuthorizationId"].nil? && !(lab && run["labAuthorizationId"] == lab["authorizationId"])
        errors << "zero-dispatch lab run #{relative(path)} references an unknown authorization"
      elsif dispatch_count.zero? && lab.nil? && run["status"] == "done"
        errors << "unauthorized zero-dispatch lab run #{relative(path)} cannot be done"
      end
      if lab && plan
        planned = {}
        Array(plan["steps"]).each do |main_step|
          planned[main_step["id"]] = { "step" => main_step, "sourceStepId" => nil, "trigger" => nil }
          Array(main_step["compensationDescriptors"]).each do |descriptor|
            planned[descriptor["id"]] = {
              "step" => descriptor,
              "sourceStepId" => main_step["id"],
              "trigger" => descriptor["trigger"]
            }
          end
        end
        errors << "lab run #{relative(path)} execution-record set differs from the approved plan" unless execution_ids.sort == planned.keys.sort
        main_ids = Array(plan["steps"]).map { |step| step["id"] }
        errors << "lab run #{relative(path)} changes approved top-level Step order" unless execution_ids.select { |id| main_ids.include?(id) } == main_ids
        execution_records.each do |record|
          binding = planned[record["id"]]
          next unless binding

          step = binding["step"]
          comparable_fields = %w[id kind effect cancellation bindingRequirement arguments]
          comparable_fields << "argumentsHash" if step.key?("argumentsHash")
          comparable_fields << "compensationDescriptors" if step.key?("compensationDescriptors")
          exact_binding = record["sourceStepId"] == binding["sourceStepId"] &&
                          record["compensationTrigger"] == binding["trigger"]
          errors << "lab run #{relative(path)} execution record #{record['id']} drifts from plan/source/trigger" unless exact_binding && comparable_fields.all? { |field| record[field] == step[field] }
        end
        Array(plan["steps"]).each do |source_step|
          source_index = execution_ids.index(source_step["id"])
          source_record = execution_records[source_index] if source_index
          Array(source_step["compensationDescriptors"]).each do |descriptor|
            record_index = execution_ids.index(descriptor["id"])
            record = execution_records[record_index] if record_index
            if record && record["disposition"] == "executed" && (!source_index || record_index <= source_index)
              errors << "lab run #{relative(path)} executes compensation #{descriptor['id']} before its source Step"
            end
            next unless record && record["disposition"] == "executed"

            trigger_satisfied = case descriptor["trigger"]
                                when "onSuccess"
                                  source_record && source_record["disposition"] == "executed" && source_record["semanticResult"] == "succeeded" && source_record["outcomeCertainty"] == "confirmed"
                                when "onFailure"
                                  source_record && source_record["disposition"] == "executed" && source_record["semanticResult"] == "failed" && source_record["outcomeCertainty"] == "confirmed"
                                when "onCancel"
                                  run["status"] == "interrupted"
                                when "onAnyTerminal"
                                  %w[done blocked interrupted superseded].include?(run["status"])
                                else
                                  false
                                end
            errors << "lab run #{relative(path)} executes compensation #{descriptor['id']} without satisfying #{descriptor['trigger']}" unless trigger_satisfied
          end
        end
      end
      if Array(task["acceptanceRefs"]).include?("AC-FLASH-014-01")
        successful_kinds = real_execution_records.select { |record| record["semanticResult"] == "succeeded" }.map { |record| record["kind"] }
        flash_index = real_execution_records.index { |record| %w[flashPartition updatePackage].include?(record["kind"]) && record["semanticResult"] == "succeeded" }
        postflight_index = real_execution_records.index { |record| record["kind"] == "verifyRemoteState" && record["semanticResult"] == "succeeded" }
        unless successful_kinds.any? { |kind| %w[flashPartition updatePackage].include?(kind) } && flash_index && postflight_index && postflight_index > flash_index
          errors << "Flash hardware run #{relative(path)} lacks an actual successful flash/update followed by semantic postflight"
        end
      end
    elsif !run["labAuthorizationId"].nil?
      errors << "standard run #{relative(path)} claims a lab authorization"
    end
    begin
      started_at = DateTime.iso8601(run.fetch("startedAt"))
      claimed_at = DateTime.iso8601(claim.fetch("claimedAt"))
      lease_expires = DateTime.iso8601(claim.fetch("leaseExpiresAt"))
      errors << "run #{relative(path)} started outside the claim lease" unless started_at >= claimed_at && started_at < lease_expires
      if !run["endedAt"].to_s.empty?
        ended_at = DateTime.iso8601(run["endedAt"])
        errors << "run #{relative(path)} ends before it starts" unless ended_at >= started_at
        errors << "run #{relative(path)} exceeds its immutable claim lease" unless ended_at <= lease_expires
        real_capabilities = Array(task["runtimeCapabilities"]) & %w[realDeviceRead realDeviceMutation destructiveDeviceMutation]
        if dispatch_count.zero?
          errors << "zero-dispatch run #{relative(path)} has dispatch timestamps" unless run["firstRealDeviceDispatchAt"].nil? && run["lastRealDeviceDispatchAt"].nil?
        elsif dispatch_count.positive? && !real_capabilities.empty?
          first_dispatch = DateTime.iso8601(run.fetch("firstRealDeviceDispatchAt"))
          last_dispatch = DateTime.iso8601(run.fetch("lastRealDeviceDispatchAt"))
          errors << "run #{relative(path)} real-device dispatch interval is outside the run" unless first_dispatch >= started_at && last_dispatch >= first_dispatch && last_dispatch <= ended_at
        else
          errors << "run #{relative(path)} records real-device dispatch without capability"
        end
        if dispatch_count.positive? && task["executionEnvironment"] == "controlledHardwareLab" && (lab = lab_authorizations[claim["claimId"]])
          lab_from = DateTime.iso8601(lab.fetch("validFrom"))
          lab_until = DateTime.iso8601(lab.fetch("validUntil"))
          approved_at = DateTime.iso8601(approvals.fetch(lab.fetch("approvalId")).fetch("approvedAt"))
          confirmed_at = DateTime.iso8601(lab.dig("physicalTargetConfirmation", "confirmedAt").to_s)
          first_dispatch = DateTime.iso8601(run.fetch("firstRealDeviceDispatchAt"))
          last_dispatch = DateTime.iso8601(run.fetch("lastRealDeviceDispatchAt"))
          unless approved_at <= first_dispatch && confirmed_at <= first_dispatch && first_dispatch >= lab_from && last_dispatch < lab_until
            errors << "run #{relative(path)} real-device dispatch was not fully pre-authorized or exceeded the lab window"
          end
        end
      end
    rescue KeyError, Date::Error, TypeError
      errors << "run #{relative(path)} has invalid start/claim timestamps"
    end

    unless run["resultRevision"].to_s.empty?
      if !git_commit?(run["baseRevision"]) || !git_commit?(run["resultRevision"])
        errors << "run #{relative(path)} base/result revision is not a real Git commit"
      elsif !git_ancestor?(run["baseRevision"], run["resultRevision"])
        errors << "run #{relative(path)} result revision is not descended from base"
      else
        actual_modified = git_diff_paths(run["baseRevision"], run["resultRevision"])
        errors << "run #{relative(path)} modifiedFiles differs from Git diff" unless actual_modified == Array(run["modifiedFiles"]).sort
      end
    end

    flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
    Array(run["modifiedFiles"]).each do |modified|
      allowed = Array(task["allowedPaths"]).any? { |pattern| File.fnmatch(pattern, modified, flags) }
      forbidden = Array(task["forbiddenPaths"]).any? { |pattern| File.fnmatch(pattern, modified, flags) }
      errors << "run #{relative(path)} modified path outside Task scope: #{modified}" unless allowed
      errors << "run #{relative(path)} modified forbidden path: #{modified}" if forbidden
    end
  end
  evidence_ids = Array(run["evidence"]).map { |item| item["evidenceId"] }
  errors << "run #{relative(path)} has duplicate evidence IDs" unless evidence_ids.uniq.length == evidence_ids.length
  Array(run["evidence"]).each do |item|
    if item["locationKind"] == "repository"
      evidence_path = ROOT.join(item["location"].to_s.delete_prefix("repo:")).expand_path
      contained = evidence_path.to_s.start_with?("#{ROOT}#{File::SEPARATOR}")
      contained &&= evidence_path.realpath.to_s.start_with?("#{ROOT.realpath}#{File::SEPARATOR}") if evidence_path.exist?
      if !contained
        errors << "run #{relative(path)} repository evidence escapes the repository: #{item['location']}"
      elsif !evidence_path.file?
        errors << "run #{relative(path)} evidence file is missing: #{item['location']}"
      elsif Digest::SHA256.file(evidence_path).hexdigest != item["sha256"]
        errors << "run #{relative(path)} evidence hash mismatch: #{item['evidenceId']}"
      end
    elsif item["locationKind"] == "controlledExternal"
      evidence_approval = approvals[item["verificationRef"]]
      valid = evidence_approval && evidence_approval["subjectType"] == "evidence" &&
              evidence_approval["subjectId"] == item["evidenceId"] &&
              evidence_approval["subjectSha256"] == item["sha256"] &&
              evidence_approval["decision"] == "approved" &&
              externally_verified?(approval_paths[evidence_approval["approvalId"]], item["location"], evidence_approval, trusted_verifiers)
      errors << "run #{relative(path)} external evidence is not verified: #{item['evidenceId']}" unless valid
    end
  end
  Array(run["acceptanceResults"]).each do |result|
    missing_evidence = Array(result["evidenceIds"]) - evidence_ids
    errors << "run #{relative(path)} acceptance #{result['acceptanceId']} has unresolved evidence" unless missing_evidence.empty?
    case_definition = case_definition_for_change.call(run["changeId"], result["acceptanceId"])
    task_verification = task && Array(task["verification"]).find { |item| item["acceptanceId"] == result["acceptanceId"] }
    errors << "run #{relative(path)} reports acceptance outside the Task: #{result['acceptanceId']}" if task_verification.nil?
    expected_test_id = case_definition && case_definition["test_id"]
    expected_method = case_definition && case_definition["method"]
    errors << "run #{relative(path)} acceptance #{result['acceptanceId']} Test ID/method drift" unless result["testId"] == expected_test_id && result["method"] == expected_method
    next unless result["result"] == "passed" && case_definition

    linked_evidence = Array(run["evidence"]).select { |item| Array(result["evidenceIds"]).include?(item["evidenceId"]) }
    minimum = case_definition["minimum_evidence"]
    has_exact_class = linked_evidence.any? { |item| item["classification"] == minimum }
    errors << "run #{relative(path)} acceptance #{result['acceptanceId']} lacks exact #{minimum} evidence" unless has_exact_class
    if minimum == "parserGolden"
      refs = Array(result["fixtureRefs"])
      errors << "run #{relative(path)} parser case has no pinned fixture" if refs.empty?
      errors << "run #{relative(path)} parser case references unknown fixture" unless (refs - conformance_fixture_ids).empty?
      required_refs = task_verification ? Array(task_verification["fixtureRefs"]) : []
      errors << "run #{relative(path)} parser case omits a Task-pinned fixture" unless (required_refs - refs).empty?
    elsif minimum == "platform"
      errors << "run #{relative(path)} platform evidence belongs to another platform" unless linked_evidence.any? { |item| item["classification"] == "platform" && item["platform"] == run["platform"] }
    elsif minimum == "realHardware"
      refs = Array(result["hardwareMatrixRefs"])
      errors << "run #{relative(path)} hardware case has no hardware evidence reference" if refs.empty?
      errors << "run #{relative(path)} hardware case references evidence without immutable historical approval" unless (refs - approved_hardware.keys).empty?
      refs.each do |hardware_id|
        record = approved_hardware[hardware_id]
        next unless record

        errors << "run #{relative(path)} hardware evidence does not cover #{result['acceptanceId']}" unless Array(record["acceptanceIds"]).include?(result["acceptanceId"])
        errors << "run #{relative(path)} hardware evidence belongs to another platform" unless record["platform"] == run["platform"]
        begin
          run_time = DateTime.iso8601(run["endedAt"].to_s.empty? ? run["startedAt"] : run["endedAt"])
          observed_at = DateTime.iso8601(record["observedAt"])
          valid_until = DateTime.iso8601(record["validUntil"])
          errors << "run #{relative(path)} hardware evidence was outside its validity window" unless run_time >= observed_at && run_time <= valid_until
        rescue Date::Error
          errors << "run #{relative(path)} hardware evidence has invalid timestamps"
        end
      end
      unless linked_evidence.any? { |item| item["classification"] == "realHardware" && item["locationKind"] == "controlledExternal" && item["platform"] == run["platform"] }
        errors << "run #{relative(path)} realHardware result lacks externally verified hardware evidence"
      end
    elsif minimum == "manualReview"
      unless linked_evidence.any? { |item| item["classification"] == "manualReview" && item["locationKind"] == "controlledExternal" }
        errors << "run #{relative(path)} manualReview result lacks externally verified review evidence"
      end
    end
  end
  valid_supersession = false
  if run["status"] == "superseded"
    replacement = task_packets[run["supersededByTaskId"]]
    replacement_path = task_packet_paths[run["supersededByTaskId"]]
    valid_supersession = valid_run_owner && valid_task_supersession?(
      run: run,
      run_path: Pathname.new(path),
      original: task,
      replacement: replacement,
      replacement_path: replacement_path && Pathname.new(replacement_path),
      approvals: approvals,
      approval_paths: approval_paths,
      verifiers: trusted_verifiers
    )
    errors << "superseded run #{relative(path)} lacks an exact approved Ready replacement with preserved scope" unless valid_supersession
    if valid_supersession
      replacement_id = run["supersededByTaskId"]
      errors << "replacement Task #{replacement_id} is authorized by more than one superseded run" if task_supersession_by_replacement.key?(replacement_id)
      task_supersession_by_replacement[replacement_id] = {
        "runId" => run["runId"],
        "approvalId" => run["supersessionApprovalId"],
        "approvedAt" => approvals.dig(run["supersessionApprovalId"], "approvedAt")
      }
    end
  end
  if valid_run_owner && %w[done blocked interrupted superseded].include?(run["status"])
    begin
      terminal_runs_by_claim[run["claimId"]] = DateTime.iso8601(run.fetch("endedAt"))
      terminal_status_by_claim[run["claimId"]] = run["status"]
      superseded_task_ids[run["taskId"]] = true if valid_supersession
    rescue KeyError, Date::Error
      errors << "terminal run #{relative(path)} has invalid endedAt"
    end
  end
  next unless run["status"] == "done"

  errors << "done run #{relative(path)} has no end/result revision" if run["endedAt"].to_s.empty? || run["resultRevision"].to_s.empty?
  errors << "done run #{relative(path)} has no commands/files/evidence" if Array(run["commands"]).empty? || Array(run["modifiedFiles"]).empty? || evidence_ids.empty?
  run_approval = approvals[run["approvalId"]]
  begin
    run_approval_after_completion = run_approval && DateTime.iso8601(run_approval.fetch("approvedAt")) >= DateTime.iso8601(run.fetch("endedAt"))
  rescue KeyError, Date::Error
    run_approval_after_completion = false
  end
  valid_run_approval = run_approval &&
                       run_approval["subjectType"] == "taskRun" &&
                       run_approval["subjectId"] == run["runId"] &&
                       run_approval["subjectRevision"] == run["attempt"] &&
                       run_approval["subjectSha256"] == Digest::SHA256.file(path).hexdigest &&
                       run_approval["baseRevision"] == run["baseRevision"] &&
                       run_approval["decision"] == "approved" &&
                       run_approval_after_completion &&
                       externally_verified?(approval_paths[run_approval["approvalId"]], path, run_approval, trusted_verifiers)
  errors << "done run #{relative(path)} lacks externally verified result approval" unless valid_run_approval
  results = Array(run["acceptanceResults"])
  errors << "done run #{relative(path)} does not cover the Task acceptance set" unless task && results.map { |item| item["acceptanceId"] }.sort == Array(task["acceptanceRefs"]).sort
  errors << "done run #{relative(path)} contains non-passing acceptance" unless results.all? { |item| item["result"] == "passed" && !Array(item["evidenceIds"]).empty? }
  valid_done = valid_run_owner && valid_run_approval && task &&
               results.map { |item| item["acceptanceId"] }.sort == Array(task["acceptanceRefs"]).sort &&
               results.all? { |item| item["result"] == "passed" && !Array(item["evidenceIds"]).empty? }
  valid_done_runs[run["runId"]] = run if valid_done
  begin
    ended_at = DateTime.iso8601(run.fetch("endedAt"))
    previous = done_run_times[run["taskId"]]
    done_run_times[run["taskId"]] = ended_at if valid_done && (previous.nil? || ended_at > previous)
  rescue KeyError, Date::Error
    errors << "done run #{relative(path)} has invalid endedAt"
  end
end

claims.each_value do |claim|
  authorization = task_supersession_by_replacement[claim["taskId"]]
  if authorization
    begin
      claimed_at = DateTime.iso8601(claim.fetch("claimedAt"))
      approved_at = DateTime.iso8601(authorization.fetch("approvedAt"))
      chronology_valid = approved_at < claimed_at
    rescue KeyError, Date::Error, TypeError
      chronology_valid = false
    end
    exact = claim["supersededRunId"] == authorization["runId"] &&
            claim["taskSupersessionApprovalId"] == authorization["approvalId"]
    errors << "replacement claim #{claim['claimId']} does not bind or strictly postdate its taskSupersession approval" unless exact && chronology_valid
  elsif !claim["supersededRunId"].nil? || !claim["taskSupersessionApprovalId"].nil?
    errors << "ordinary claim #{claim['claimId']} carries an unresolved taskSupersession authorization"
  end
end

validate_hardware_provenance = lambda do |evidence_id, record, bundle|
  run = bundle && bundle["run"]
  task = bundle && bundle["task"]
  lab = bundle && bundle["lab"]
  plan = bundle && bundle["plan"]
  target = lab && lab["target"]
  definition_for = lambda do |acceptance_id|
    bundle&.dig("caseDefinitions", acceptance_id) ||
      (run && case_definition_for_change.call(run["changeId"], acceptance_id))
  end
  real_results = Array(run && run["acceptanceResults"]).select do |result|
    definition = definition_for.call(result["acceptanceId"])
    result["result"] == "passed" && definition && definition["minimum_evidence"] == "realHardware"
  end
  origin_acceptance_ids = real_results.map { |result| result["acceptanceId"] }.sort
  origin_evidence = Array(run && run["evidence"]).find { |item| item["evidenceId"] == record["runEvidenceId"] }
  result_links_origin = real_results.all? { |result| Array(result["evidenceIds"]).include?(record["runEvidenceId"]) }
  actual_step_kinds = Array(bundle && bundle["realExecutionRecords"]).map { |step| step["kind"] }.uniq.sort
  expected_capabilities = origin_acceptance_ids.map do |id|
    definition_for.call(id)&.dig("hardware_capability")
  end.compact.uniq.sort
  expected_case_bindings = real_results.map do |result|
    definition = definition_for.call(result["acceptanceId"])
    {
      "acceptanceId" => result["acceptanceId"],
      "testId" => definition && definition["test_id"],
      "method" => definition && definition["method"],
      "minimumEvidence" => definition && definition["minimum_evidence"],
      "hardwareCapability" => definition && definition["hardware_capability"],
      "definitionSha256" => acceptance_case_contract_sha256(result["acceptanceId"], definition)
    }
  end.sort_by { |binding| binding["acceptanceId"] }
  actual_case_bindings = Array(record["acceptanceCaseBindings"]).sort_by { |binding| binding["acceptanceId"].to_s }
  platform_context = bundle && bundle["platformContext"]
  platform_entry = platform_context && platform_context["entry"]
  platform_case_document = platform_context && platform_context["caseDocument"]
  historical_support_cell_ids = Array(platform_case_document && platform_case_document["support_cells"]).map { |cell| cell["id"] }
  valid = run && run["status"] == "done" && run["realDeviceDispatchCount"].to_i.positive? && task && task["executionEnvironment"] == "controlledHardwareLab" &&
          record["implementationRevision"] == run["resultRevision"] &&
          lab && plan && record["labAuthorizationId"] == lab["authorizationId"] &&
          record["executionPlanSha256"] == lab["planSha256"] && run["executionPlanSha256"] == lab["planSha256"] &&
          record["platform"] == run["platform"] && record.dig("device", "identity") == target["deviceIdentity"] &&
          record.dig("device", "bindingRevision") == target["bindingRevision"] && record.dig("device", "build") == target["firmware"] &&
          record["transport"] == target["transport"] && record.dig("toolchain", "hdcSha256") == target["hdcExecutableSha256"] &&
          record.dig("toolchain", "clientVersion") == target["hdcClientVersion"] &&
          record.dig("toolchain", "serverVersion") == target["hdcServerVersion"] &&
          record.dig("toolchain", "daemonVersion") == target["hdcDaemonVersion"] &&
          record.dig("toolchain", "serverEndpoint") == target["hdcServerEndpoint"] &&
          record.dig("toolchain", "serverGeneration") == target["hdcServerGeneration"] &&
          record.dig("provider", "id") == target["providerId"] && record.dig("provider", "version") == target["providerVersion"] &&
          Array(record["acceptanceIds"]).sort == origin_acceptance_ids && !origin_acceptance_ids.empty? &&
          actual_case_bindings == expected_case_bindings && platform_entry &&
          record["platformCaseManifestSha256"] == platform_entry["case_manifest_sha256"] &&
          historical_support_cell_ids.include?(record["hostSupportCellId"]) &&
          Array(record["stepKinds"]).sort == actual_step_kinds && !actual_step_kinds.empty? && Array(record["capabilities"]).sort == expected_capabilities.sort &&
          origin_evidence && origin_evidence["classification"] == "realHardware" && origin_evidence["locationKind"] == "controlledExternal" &&
          origin_evidence["sha256"] == record.dig("artifact", "sha256") && origin_evidence["location"] == record.dig("artifact", "location") &&
          result_links_origin
  if run
    begin
      observed_at = DateTime.iso8601(record.fetch("observedAt"))
      started_at = DateTime.iso8601(run.fetch("startedAt"))
      ended_at = DateTime.iso8601(run.fetch("endedAt"))
      valid &&= observed_at >= started_at && observed_at <= ended_at
    rescue KeyError, Date::Error
      valid = false
    end
  end
  errors << "verified hardware evidence #{evidence_id} is not bound to its approved lab run/plan/target" unless valid
end

pending_archived_hardware = []
approved_hardware.each do |evidence_id, record|
  run = valid_done_runs[record["taskRunId"]]
  if run
    claim = claims[run["claimId"]]
    task = claim && task_packets[claim["taskId"]]
    validate_hardware_provenance.call(
      evidence_id,
      record,
      {
        "run" => run,
        "task" => task,
        "lab" => claim && lab_authorizations[claim["claimId"]],
        "plan" => claim && lab_plans[claim["claimId"]],
        "realExecutionRecords" => real_execution_records_by_run_id[run["runId"]],
        "platformContext" => platform_context_for_task(run["resultRevision"], task),
        "caseDefinitions" => {}
      }
    )
  else
    pending_archived_hardware << [evidence_id, record]
  end
end

effective_claim_intervals = claim_intervals.map do |claim_id, task_id, claimed_at, lease_expires, resources|
  [claim_id, task_id, claimed_at, terminal_runs_by_claim[claim_id] || lease_expires, resources]
end
effective_claim_intervals.combination(2) do |left, right|
  same_task = left[1] == right[1]
  shared_resource = !(left[4] & right[4]).empty?
  next unless same_task || shared_resource
  next unless left[2] < right[3] && right[2] < left[3]

  errors << "overlapping active claims #{left[0]} and #{right[0]} target the same Task or resource"
end

claims.values.group_by { |claim| claim["taskId"] }.each_value do |task_claims|
  ordered = task_claims.sort_by { |claim| claim["attempt"] }
  errors << "Task #{ordered.first['taskId']} first claim attempt is not 1" unless ordered.empty? || ordered.first["attempt"] == 1
  ordered.each_cons(2) do |previous, following|
    errors << "Task #{following['taskId']} attempts are not consecutive" unless following["attempt"] == previous["attempt"] + 1
    previous_ended = terminal_runs_by_claim[previous["claimId"]]
    errors << "claim #{following['claimId']} follows a superseded Task" if terminal_status_by_claim[previous["claimId"]] == "superseded"
    begin
      following_claimed = DateTime.iso8601(following["claimedAt"])
      unless previous_ended && previous_ended <= following_claimed
        errors << "claim #{following['claimId']} starts before the prior attempt has a terminal run"
      end
    rescue Date::Error
      # Claim timestamp error is reported above.
    end
  end
end

claims.each_value do |claim|
  task = task_packets[claim["taskId"]]
  next unless task

  begin
    claimed_at = DateTime.iso8601(claim["claimedAt"])
    Array(task["dependsOn"]).each do |dependency|
      completed_at = done_run_times[dependency]
      errors << "claim #{claim['claimId']} dependency #{dependency} was not done before claim" unless completed_at && completed_at <= claimed_at
    end
  rescue Date::Error
    # Timestamp error is reported on the claim itself.
  end
end

# Successor approval is a fail-closed, serialized transition: every predecessor
# claim must already have an owner-attested terminal run. This prevents an
# approved replacement from racing an old lease or authorizing two scopes at once.
effective_change_successors.each do |predecessor_id, successor|
  predecessor_claims = claims.values.select { |claim| claim["changeId"] == predecessor_id }
  predecessor_claims.each do |claim|
    begin
      claimed_at = DateTime.iso8601(claim.fetch("claimedAt"))
      terminal_at = terminal_runs_by_claim[claim["claimId"]]
      unless claim_precedes_successor?(claimed_at: claimed_at, successor_approved_at: successor["approved_at"])
        # The direct claim check above reports this as a post-revocation claim.
        next
      end
      unless predecessor_claim_closed_before_successor?(
        claimed_at: claimed_at,
        terminal_at: terminal_at,
        successor_approved_at: successor["approved_at"]
      )
        errors << "successor Change #{successor['change_id']} was approved before predecessor claim #{claim['claimId']} had an owner-attested terminal run"
      end
    rescue KeyError, Date::Error
      # Timestamp errors are reported on the claim/run itself.
    end
  end
end

Dir.glob(ROOT.join("openspec/changes/chg-*/proposal.md")).sort.each do |proposal_path_string|
  proposal_path = Pathname.new(proposal_path_string)
  change_root = proposal_path.parent
  proposal = markdown_frontmatter(proposal_path)
  change_id = proposal["id"]
  status = proposal["status"]
  expected_id = change_root.basename.to_s.sub(/\Achg-/, "CHG-")
  errors << "change #{relative(change_root)} proposal identity mismatch" unless change_id.to_s.downcase == expected_id.downcase
  errors << "change #{change_id || relative(change_root)} V1 revision must remain 1" unless proposal["revision"] == 1
  supersedes_change_id = proposal["supersedes_change_id"]
  barrier_attestation_id = proposal["supersession_barrier_attestation_id"]
  valid_supersedes = supersedes_change_id.nil? || (supersedes_change_id.to_s.match?(/\ACHG-[0-9]{4}-[0-9]{3}(?:-[A-Za-z0-9-]+)?\z/) && supersedes_change_id != change_id)
  errors << "change #{change_id || relative(change_root)} has an invalid supersedes_change_id" unless valid_supersedes
  valid_barrier_id = supersedes_change_id.nil? ? barrier_attestation_id.nil? : barrier_attestation_id.to_s.match?(/\ACHGSUPAUTH-[A-Z0-9._-]+\z/)
  errors << "change #{change_id || relative(change_root)} has an invalid supersession barrier preallocation" unless valid_barrier_id
  errors << "change #{change_id || relative(change_root)} proposal source status must remain proposed" unless status == "proposed"

  required_change_artifact_paths(change_root, proposal).each do |artifact_path|
    errors << "change #{change_id || relative(change_root)} is missing required artifact #{artifact_path.basename}" unless artifact_path.file?
  end
  delta_paths = Dir.glob(change_root.join("specs/**/*.md").to_s)
  case proposal["schema"]
  when "arkdeck-behavior"
    errors << "behavior change #{change_id} has no delta spec" if delta_paths.empty?
    errors << "behavior change #{change_id} must not carry spec-impact.md" if change_root.join("spec-impact.md").file?
  when "arkdeck-platform"
    errors << "platform change #{change_id} must not carry behavior delta specs" unless delta_paths.empty?
  else
    errors << "change #{change_id || relative(change_root)} has an unknown schema"
  end

  lock_path = change_root.join("change-lock.yaml")
  if lock_path.file?
      lock = YAML.safe_load(lock_path.read, aliases: true) || {}
      entries = Array(lock["files"])
      lock_paths = entries.map { |entry| entry["path"] }
      identity_valid = lock["change_id"] == change_id && lock["revision"] == proposal["revision"] && lock["hash_algorithm"] == "sha256"
      errors << "change #{change_id} lock identity/revision/hash algorithm mismatch" unless identity_valid
      errors << "change #{change_id} lock is not the exact input set" unless lock_paths.sort == expected_change_input_paths(change_root)
      errors << "change #{change_id} lock has duplicate paths" unless lock_paths.uniq.length == lock_paths.length
      case lock["status"]
      when "review"
        errors << "review change #{change_id} lock must be non-authorizing" unless lock["approval_id"].nil?
        entries.each do |entry|
          locked_path = ROOT.join(entry["path"].to_s)
          hash_is_draft_or_exact = entry["sha256"] == "pending" ||
                                   (locked_path.file? && Digest::SHA256.file(locked_path).hexdigest == entry["sha256"])
          errors << "review change #{change_id} lock has an invalid draft hash: #{entry['path']}" unless hash_is_draft_or_exact
        end
      when "approved"
        review_status = change_root.join("review.md").read[/^> Status：([^\s]+)\s*$/, 1] if change_root.join("review.md").file?
        ready_review_status = change_root.join("ready-review.md").read[/^> Status：([^\s]+)\s*$/, 1] if change_root.join("ready-review.md").file?
        errors << "approved change #{change_id} requires passed review and ready-review gates" unless review_status == "passed" && ready_review_status == "passed"
        entries.each do |entry|
          locked_path = ROOT.join(entry["path"].to_s)
          errors << "approved change #{change_id} input drift: #{entry['path']}" unless locked_path.file? && Digest::SHA256.file(locked_path).hexdigest == entry["sha256"]
        end
        approval = approvals[lock["approval_id"]]
        valid = approval && approval["subjectType"] == "change" &&
                approval["subjectId"] == change_id &&
                approval["subjectRevision"] == proposal["revision"] &&
                approval["subjectSha256"] == Digest::SHA256.file(lock_path).hexdigest &&
                approval["decision"] == "approved" && git_commit?(approval["baseRevision"]) &&
                externally_verified?(approval_paths[approval["approvalId"]], lock_path, approval, trusted_verifiers)
        errors << "approved change #{change_id} has no externally verified change approval" unless valid
      else
        errors << "change #{change_id} lock has an unsupported status"
      end
  end

  verification_result_path = change_root.join("verification-result.json")
  if verification_result_path.file?
    verification_result = JSON.parse(verification_result_path.read)
    verification_path = change_root.join("verification.md")
    active_tasks = task_packets.select { |id, packet| packet["changeId"] == change_id && !superseded_task_ids[id] }.keys
    errors << "verified change #{change_id} has no active Task packets" if active_tasks.empty?
    errors << "verified change #{change_id} has unfinished Task packets" unless (active_tasks - done_run_times.keys).empty?
    scope = change_scopes[change_id] || {}
    active_requirement_scope = active_tasks.flat_map { |task_id| Array(task_packets.dig(task_id, "requirementRefs")) }.uniq.sort
    active_acceptance_scope = active_tasks.flat_map { |task_id| Array(task_packets.dig(task_id, "acceptanceRefs")) }.uniq.sort
    errors << "verified change #{change_id} active Task Requirement union differs from immutable scope" unless active_requirement_scope == Array(scope["requirements"]).sort
    errors << "verified change #{change_id} active Task Acceptance union differs from immutable scope" unless active_acceptance_scope == Array(scope["acceptance"]).sort
    task_run_entries = Array(verification_result["taskRuns"])
    task_run_ids = task_run_entries.map { |entry| entry["taskId"] }
    errors << "verified change #{change_id} result does not exactly cover active Tasks" unless task_run_ids.sort == active_tasks.sort && task_run_ids.uniq.length == task_run_ids.length
    bound_runs = {}
    task_run_entries.each do |entry|
      run = valid_done_runs[entry["runId"]]
      run_path = run_paths_by_id[entry["runId"]]
      exact = run && run_path && run["taskId"] == entry["taskId"] && run["changeId"] == change_id &&
              entry["runSha256"] == Digest::SHA256.file(run_path).hexdigest && entry["resultRevision"] == run["resultRevision"] &&
              git_ancestor?(run["resultRevision"], verification_result["resultRevision"])
      errors << "verified change #{change_id} result has an invalid Task run binding for #{entry['taskId']}" unless exact
      bound_runs[entry["runId"]] = run if exact
    end

    change_lock_doc = lock_path.file? ? (YAML.safe_load(lock_path.read, aliases: false) || {}) : {}
    change_approval = approvals[change_lock_doc["approval_id"]]
    aggregate_base_revision = change_approval && change_approval["baseRevision"]
    aggregate_base_exact = active_tasks.all? do |task_id|
      task_packets.dig(task_id, "baseRevision") == aggregate_base_revision
    end
    errors << "verified change #{change_id} active Tasks do not share the exact change-approval base" unless aggregate_base_exact

    provenance_files = {}
    add_provenance_file = lambda do |revision_path, filesystem_path|
      path = Pathname.new(filesystem_path)
      provenance_files[revision_path] = Digest::SHA256.file(path).hexdigest if path.file?
    end
    tasks_path = change_root.join("tasks.md")
    add_provenance_file.call(relative(tasks_path), tasks_path)
    task_packets.each do |task_id, packet|
      next unless packet["changeId"] == change_id

      add_provenance_file.call(relative(task_packet_paths[task_id]), task_packet_paths[task_id])
    end
    evidence_summary_path = change_root.join("evidence/summary.md")
    add_provenance_file.call(relative(evidence_summary_path), evidence_summary_path)
    barrier_path = change_records.dig(change_id, "barrier", "path")
    add_provenance_file.call(relative(barrier_path), barrier_path) if barrier_path

    approval_ids = [
      change_lock_doc["approval_id"],
      trust_policy.dig("ratification", "approval_ref"),
      baseline && baseline.dig("ratification", "approval_ref"),
      integration_lock && integration_lock.dig("ratification", "approval_ref"),
      platform_lock && platform_lock.dig("ratification", "approval_ref"),
      conformance && conformance.dig("ratification", "approval_ref")
    ]
    claims.each do |claim_id, claim|
      next unless claim["changeId"] == change_id

      claim_path = claim_paths_by_id[claim_id]
      if claim_path
        add_provenance_file.call(relative(claim_path), claim_path)
        %w[
          claim-owner-attestation.json
          resource-identity-attestation.json
          lab-execution-plan.json
          lab-execution-authorization.json
        ].each do |name|
          sidecar_path = claim_path.parent.join(name)
          add_provenance_file.call(relative(sidecar_path), sidecar_path)
        end
      end
      approval_ids << claim["approvalId"]
      lab = lab_authorizations[claim_id]
      approval_ids << lab["approvalId"] if lab
    end
    runs_by_id.each do |run_id, run|
      next unless run["changeId"] == change_id

      run_path = run_paths_by_id[run_id]
      if run_path
        add_provenance_file.call(relative(run_path), run_path)
        owner_path = run_path.parent.join("run-owner-attestation.json")
        add_provenance_file.call(relative(owner_path), owner_path)
      end
      approval_ids.concat([run["approvalId"], run["supersessionApprovalId"]])
      Array(run["evidence"]).each { |item| approval_ids << item["verificationRef"] }
      Array(run["acceptanceResults"]).flat_map { |item| Array(item["hardwareMatrixRefs"]) }.uniq.each do |evidence_id|
        evidence_path = hardware_evidence_paths[evidence_id]
        record = approved_hardware[evidence_id]
        if evidence_path && record
          add_provenance_file.call(relative(evidence_path), evidence_path)
          approval_ids << record["approvalId"]
        end
      end
    end
    task_packets.each_value do |packet|
      approval_ids << packet["approvalId"] if packet["changeId"] == change_id
    end
    approval_ids.compact.uniq.each do |approval_id|
      approval_path = approval_paths[approval_id]
      add_provenance_file.call(relative(approval_path), approval_path) if approval_path
    end
    aggregate_valid = aggregate_base_exact && validate_task_result_aggregate(
      errors: errors,
      subject: "verified change #{change_id}",
      base_revision: aggregate_base_revision,
      result_revision: verification_result["resultRevision"],
      runs: bound_runs.values,
      provenance_files: provenance_files
    )
    expected_acceptance = active_tasks.flat_map { |task_id| Array(task_packets.dig(task_id, "acceptanceRefs")) }.uniq.sort
    result_acceptance = Array(verification_result["acceptanceResults"])
    result_acceptance_ids = result_acceptance.map { |entry| entry["acceptanceId"] }
    errors << "verified change #{change_id} result does not exactly cover active Task ACs" unless result_acceptance_ids.sort == expected_acceptance && result_acceptance_ids.uniq.length == result_acceptance_ids.length
    result_acceptance.each do |entry|
      run = bound_runs[entry["runId"]]
      run_result = Array(run && run["acceptanceResults"]).find { |candidate| candidate["acceptanceId"] == entry["acceptanceId"] }
      definition = case_definition_for_change.call(change_id, entry["acceptanceId"])
      exact = run_result && run_result["result"] == "passed" && entry["result"] == "passed" && definition &&
              entry["testId"] == definition["test_id"] && run_result["testId"] == entry["testId"]
      errors << "verified change #{change_id} result has an invalid AC/run binding for #{entry['acceptanceId']}" unless exact
    end
    verification_approval = approvals[verification_result["approvalId"]]
    begin
      latest_task_completion = bound_runs.values.map { |run| DateTime.iso8601(run.fetch("endedAt")) }.max
      verified_at = DateTime.iso8601(verification_result.fetch("verifiedAt"))
      verification_approved_at = DateTime.iso8601(verification_approval.fetch("approvedAt")) if verification_approval
      valid_times = latest_task_completion && verified_at >= latest_task_completion && verification_approval && verification_approved_at >= verified_at
      if (successor = effective_change_successors[change_id]) && verification_approved_at >= successor["approved_at"]
        errors << "superseded Change #{change_id} was verified after successor #{successor['change_id']} became effective"
        valid_times = false
      end
    rescue KeyError, Date::Error, NoMethodError
      valid_times = false
    end
    valid = lock_path.file? && verification_path.file? &&
            verification_result["changeId"] == change_id && verification_result["changeRevision"] == proposal["revision"] &&
            verification_result["status"] == "passed" && verification_result["changeLockSha256"] == Digest::SHA256.file(lock_path).hexdigest &&
            verification_result["verificationPlanSha256"] == Digest::SHA256.file(verification_path).hexdigest &&
            git_commit?(verification_result["resultRevision"]) && git_ancestor?(verification_result["resultRevision"], git_head_revision) && aggregate_valid && valid_times && verification_approval &&
            verification_approval["subjectType"] == "changeVerification" &&
            verification_approval["subjectId"] == verification_result["verificationId"] &&
            verification_approval["subjectRevision"] == proposal["revision"] &&
            verification_approval["subjectSha256"] == Digest::SHA256.file(verification_result_path).hexdigest &&
            verification_approval["baseRevision"] == verification_result["resultRevision"] &&
            verification_approval["decision"] == "approved" &&
            externally_verified?(approval_paths[verification_approval["approvalId"]], verification_result_path, verification_approval, trusted_verifiers)
    errors << "verified change #{change_id} lacks an exact externally verified immutable verification result" unless valid
  end
end

archived_hardware_provenance = {}
Dir.glob(ROOT.join("openspec/changes/archive/*")).sort.each do |archive_path_string|
  archive_root = Pathname.new(archive_path_string)
  next unless archive_root.directory?

  errors << "invalid archive directory name: #{relative(archive_root)}" unless archive_root.basename.to_s.match?(/\A\d{4}-\d{2}-\d{2}-chg-\d{4}-\d{3}(?:-[a-z0-9-]+)?\z/)
  proposal_path = archive_root.join("proposal.md")
  scope_path = archive_root.join("scope.yaml")
  verification_path = archive_root.join("verification.md")
  verification_result_path = archive_root.join("verification-result.json")
  archive_lock_path = archive_root.join("archive-lock.yaml")
  if !proposal_path.file? || !scope_path.file? || !verification_path.file? || !verification_result_path.file? || !archive_lock_path.file?
    errors << "archive #{relative(archive_root)} lacks proposal/scope, immutable verification plan/result or archive lock"
    next
  end
  verification_result = JSON.parse(verification_result_path.read)
  verification_approval = approvals[verification_result["approvalId"]]
  verification_approval_path = verification_approval && approval_paths[verification_approval["approvalId"]]
  proposal = markdown_frontmatter(proposal_path)
  archive_case_registry_path = archive_root.join("acceptance-cases.yaml")
  archive_case_registry = archive_case_registry_path.file? ? (YAML.safe_load(archive_case_registry_path.read, aliases: false) || {}) : {}
  archive_local_case_definitions = Array(archive_case_registry["cases"]).to_h do |item|
    [item["acceptance_id"], item]
  end
  errors << "archive #{relative(archive_root)} proposal source status was mutated" unless proposal["status"] == "proposed"
  errors << "archive #{relative(archive_root)} has an unsupported in-place Change revision" unless proposal["revision"] == 1
  archive_barrier_id = proposal["supersession_barrier_attestation_id"]
  archive_predecessor_id = proposal["supersedes_change_id"]
  archive_barrier_binding_valid = archive_predecessor_id.nil? ? archive_barrier_id.nil? : archive_barrier_id.to_s.match?(/\ACHGSUPAUTH-[A-Z0-9._-]+\z/)
  errors << "archive #{relative(archive_root)} has an invalid supersession barrier preallocation" unless archive_barrier_binding_valid
  lock = YAML.safe_load(archive_lock_path.read, permitted_classes: [Date, Time], aliases: true) || {}
  all_files = Dir.glob(archive_root.join("**/*")).select { |path| File.file?(path) && Pathname.new(path) != archive_lock_path }.map { |path| relative(path) }.sort
  entries = Array(lock["files"])
  errors << "archive #{relative(archive_root)} lock file set is not exact" unless entries.map { |entry| entry["path"] }.sort == all_files
  errors << "archive #{relative(archive_root)} lock has duplicate paths" unless entries.map { |entry| entry["path"] }.uniq.length == entries.length
  entries.each do |entry|
    entry_path = ROOT.join(entry["path"].to_s)
    errors << "archive #{relative(archive_root)} file drift: #{entry['path']}" unless entry_path.file? && Digest::SHA256.file(entry_path).hexdigest == entry["sha256"]
  end
  pre_archive_path = archive_root.join("pre-archive-verification.json")
  pre_archive_record = pre_archive_path.file? ? JSON.parse(pre_archive_path.read) : {}
  pre_archive_ref = lock["pre_archive_verification"].is_a?(Hash) ? lock["pre_archive_verification"] : {}
  source_files = Dir.glob(archive_root.join("**/*")).select do |entry|
    File.file?(entry) && ![archive_lock_path, pre_archive_path].include?(Pathname.new(entry))
  end.map do |entry|
    entry_path = Pathname.new(entry)
    {
      "path" => entry_path.relative_path_from(archive_root).to_s,
      "sha256" => Digest::SHA256.file(entry_path).hexdigest
    }
  end.sort_by { |entry| entry["path"] }
  validated_files = Array(pre_archive_record["validatedFiles"])
  validated_paths = validated_files.map { |entry| entry["path"] }
  pre_archive_approval = approvals[pre_archive_record["approvalId"]]
  verification_revision = lock["verification_revision"]
  source_tree_revision = lock["source_tree_revision"]
  historical_core_case_source = git_file_content(verification_revision, "openspec/verification/acceptance-cases.yaml")
  historical_core_case_definitions = {}
  begin
    historical_core_case_document = YAML.safe_load(historical_core_case_source.to_s, aliases: false) || {}
    historical_core_case_definitions = Array(historical_core_case_document["cases"]).to_h do |item|
      [item["acceptance_id"], item]
    end
  rescue Psych::Exception
    errors << "archive #{relative(archive_root)} cannot parse its historical Core acceptance registry"
  end
  archive_case_definitions = historical_core_case_definitions.merge(archive_local_case_definitions)
  begin
    pre_archive_validated_at = DateTime.iso8601(pre_archive_record.fetch("validatedAt"))
    pre_archive_approved_at = DateTime.iso8601(pre_archive_approval.fetch("approvedAt")) if pre_archive_approval
    valid_pre_archive_time = pre_archive_approval && pre_archive_approved_at >= pre_archive_validated_at
  rescue KeyError, Date::Error
    pre_archive_validated_at = nil
    valid_pre_archive_time = false
  end
  pre_archive_valid = pre_archive_path.file? &&
                      pre_archive_ref["path"] == "pre-archive-verification.json" &&
                      pre_archive_ref["sha256"] == Digest::SHA256.file(pre_archive_path).hexdigest &&
                      pre_archive_record["subjectType"] == "archiveSourceVerification" &&
                      pre_archive_record["changeId"] == proposal["id"] &&
                      pre_archive_record["changeRevision"] == proposal["revision"] &&
                      pre_archive_record["sourceRevision"] == source_tree_revision &&
                      pre_archive_record["sourceChangeLockSha256"] == lock["source_change_lock_sha256"] &&
                      pre_archive_record["guardContract"] == "ARKDECK-ARCHIVE-SEMANTICS-1" &&
                      pre_archive_record["result"] == "passed" &&
                      Array(pre_archive_record["invariants"]).sort == PRE_ARCHIVE_INVARIANTS.sort &&
                      validated_paths == validated_paths.sort && validated_paths.uniq.length == validated_paths.length &&
                      validated_files == source_files && valid_pre_archive_time &&
                      pre_archive_approval["subjectType"] == "archiveSourceVerification" &&
                      pre_archive_approval["subjectId"] == pre_archive_record["verificationId"] &&
                      pre_archive_approval["subjectRevision"] == proposal["revision"] &&
                      pre_archive_approval["subjectSha256"] == Digest::SHA256.file(pre_archive_path).hexdigest &&
                      pre_archive_approval["baseRevision"] == pre_archive_record["sourceRevision"] &&
                      pre_archive_approval["decision"] == "approved" &&
                      externally_verified?(approval_paths[pre_archive_approval["approvalId"]], pre_archive_path, pre_archive_approval, trusted_verifiers)
  errors << "archive #{relative(archive_root)} lacks an exact externally verified pre-move semantic guard attestation" unless pre_archive_valid
  source_change_lock = archive_root.join("change-lock.yaml")
  source_change_lock_doc = source_change_lock.file? ? (YAML.safe_load(source_change_lock.read, aliases: true) || {}) : {}
  result_baseline_relative = lock.dig("result_core_baseline", "path").to_s
  result_baseline = ROOT.join(result_baseline_relative).expand_path
  baseline_contained = result_baseline_relative.match?(/\Aopenspec\/baselines\/CORE-[0-9]+\.[0-9]+\.[0-9]+\.lock\.yaml\z/) &&
                       result_baseline.to_s.start_with?("#{ROOT}#{File::SEPARATOR}")
  result_baseline_doc = result_baseline.file? ? (YAML.safe_load(result_baseline.read, permitted_classes: [Date, Time], aliases: true) || {}) : {}
  result_revision = lock["result_revision"]
  staged_archive_paths = git_tree_paths(result_revision, relative(archive_root))
  staged_archive_exact = staged_archive_paths == entries.map { |entry| entry["path"] }.sort &&
                         entries.all? { |entry| git_file_sha256(result_revision, entry["path"].to_s) == entry["sha256"] } &&
                         git_file_content(result_revision, relative(archive_lock_path)).nil?
  errors << "archive #{relative(archive_root)} staging tree is not the exact lock-excluded archive subject" unless staged_archive_exact
  archive_baseline_integrity = result_baseline.file? &&
                               git_file_sha256(result_revision, result_baseline_relative) == Digest::SHA256.file(result_baseline).hexdigest
  walk_hash_entries(result_baseline_doc) do |entry|
    pinned_path = ROOT.join(entry["path"].to_s).expand_path
    archive_baseline_integrity &&= pinned_path.to_s.start_with?("#{ROOT}#{File::SEPARATOR}") &&
                                  pinned_path.file? && Digest::SHA256.file(pinned_path).hexdigest == entry["sha256"]
  end
  archive_manifest_relative = result_baseline_doc.dig("file_manifest", "path").to_s
  archive_manifest_path = ROOT.join(archive_manifest_relative).expand_path
  manifest_contained = archive_manifest_relative.match?(/\Aopenspec\/baselines\/CORE-[0-9]+\.[0-9]+\.[0-9]+\.files\.yaml\z/) &&
                       archive_manifest_path.to_s.start_with?("#{ROOT}#{File::SEPARATOR}")
  if manifest_contained && archive_manifest_path.file?
    archive_manifest = YAML.safe_load(archive_manifest_path.read, permitted_classes: [Date, Time], aliases: true) || {}
    manifest_entries = Array(archive_manifest["files"])
    manifest_paths = manifest_entries.map { |entry| entry["path"] }
    archive_baseline_integrity &&= archive_manifest["baseline"] == result_baseline_doc["baseline"] &&
                                  manifest_paths == manifest_paths.sort && manifest_paths.uniq.length == manifest_paths.length &&
                                  git_file_sha256(result_revision, archive_manifest_relative) == Digest::SHA256.file(archive_manifest_path).hexdigest
    manifest_entries.each do |entry|
      archive_baseline_integrity &&= git_file_sha256(result_revision, entry["path"].to_s) == entry["sha256"]
    end
  else
    archive_baseline_integrity = false
  end
  historical_platform_source = git_file_content(result_revision, "openspec/platforms/PLATFORM-PROFILES.lock.yaml")
  historical_conformance_source = git_file_content(result_revision, "openspec/verification/core-conformance.yaml")
  historical_platform_doc = {}
  historical_conformance_doc = {}
  begin
    historical_platform_doc = YAML.safe_load(historical_platform_source.to_s, permitted_classes: [Date, Time], aliases: false) || {}
    historical_conformance_doc = YAML.safe_load(historical_conformance_source.to_s, permitted_classes: [Date, Time], aliases: false) || {}
  rescue Psych::Exception
    errors << "archive #{relative(archive_root)} result axes cannot be parsed from its fixed staging revision"
  end
  result_platform_lock_chain = (git_tree_paths(result_revision, "openspec/platforms/history") || []).filter_map do |path|
    next unless path.match?(/\Aopenspec\/platforms\/history\/PLATFORM-PROFILES-[A-Za-z0-9._-]+\.lock\.yaml\z/)

    source = git_file_content(result_revision, path)
    begin
      { "path" => path, "source" => source, "document" => YAML.safe_load(source.to_s, permitted_classes: [Date, Time], aliases: false) || {} }
    rescue Psych::Exception
      errors << "archive #{relative(archive_root)} cannot parse historical Platform lock #{path}"
      nil
    end
  end
  result_platform_lock_chain << {
    "path" => "openspec/platforms/PLATFORM-PROFILES.lock.yaml",
    "source" => historical_platform_source,
    "document" => historical_platform_doc
  }
  result_platform_revalidation_context = result_baseline_doc["platform_revalidation_context"].is_a?(Hash) ?
                                           result_baseline_doc["platform_revalidation_context"] : {}
  result_revalidation_lock_record = result_platform_lock_chain.find do |record|
    document = record["document"]
    source = record["source"]
    source && document["lock"] == result_platform_revalidation_context["platform_lock"] &&
      document["revision"] == result_platform_revalidation_context["revision"] &&
      Digest::SHA256.hexdigest(source.b) == result_platform_revalidation_context["sha256"]
  end
  result_revalidation_context_valid = result_revalidation_lock_record &&
                                      Array(result_revalidation_lock_record.dig("document", "current_delivery_platforms")).map(&:to_s).sort ==
                                      Array(result_platform_revalidation_context["current_delivery_platforms"]).map(&:to_s).sort
  archive_baseline_integrity &&= result_revalidation_context_valid
  historical_platform_approval = approvals[historical_platform_doc.dig("ratification", "approval_ref")]
  historical_conformance_approval = approvals[historical_conformance_doc.dig("ratification", "approval_ref")]
  historical_platform_changed = git_file_sha256(source_tree_revision, "openspec/platforms/PLATFORM-PROFILES.lock.yaml") !=
                                Digest::SHA256.hexdigest(historical_platform_source.to_s.b)
  historical_conformance_changed = git_file_sha256(source_tree_revision, "openspec/verification/core-conformance.yaml") !=
                                   Digest::SHA256.hexdigest(historical_conformance_source.to_s.b)
  historical_platform_valid = historical_platform_doc["status"] == "accepted" && historical_platform_doc["execution_gate"] == "open" &&
                              valid_historical_approval?(
                                source: historical_platform_source,
                                subject_name: "PLATFORM-PROFILES.lock.yaml",
                                document: historical_platform_doc,
                                approval: historical_platform_approval,
                                approval_path: historical_platform_approval && approval_paths[historical_platform_approval["approvalId"]],
                                subject_type: "platformLock",
                                subject_id: historical_platform_doc["lock"],
                                result_revision: result_revision,
                                verifiers: trusted_verifiers,
                                exact_base: historical_platform_changed
                              )
  historical_conformance_valid = historical_conformance_doc["status"] == "accepted" && historical_conformance_doc["execution_gate"] == "open" &&
                                 historical_conformance_doc["core_baseline"] == result_baseline_doc["baseline"] &&
                                 valid_historical_approval?(
                                   source: historical_conformance_source,
                                   subject_name: "core-conformance.yaml",
                                   document: historical_conformance_doc,
                                   approval: historical_conformance_approval,
                                   approval_path: historical_conformance_approval && approval_paths[historical_conformance_approval["approvalId"]],
                                   subject_type: "conformanceSuite",
                                   subject_id: historical_conformance_doc["suite"],
                                   result_revision: result_revision,
                                   verifiers: trusted_verifiers,
                                   exact_base: historical_conformance_changed
                                 )
  errors << "archive #{relative(archive_root)} historical Platform lock is not exact and accepted" unless historical_platform_valid
  errors << "archive #{relative(archive_root)} historical Conformance suite is not exact and accepted" unless historical_conformance_valid
  base_snapshot = git_normative_spec_snapshot(
    revision: lock["base_revision"],
    errors: errors,
    subject: "archive #{relative(archive_root)} predecessor specs"
  )
  result_snapshot = git_normative_spec_snapshot(
    revision: result_revision,
    errors: errors,
    subject: "archive #{relative(archive_root)} result specs"
  )
  archive_behavior_overlay_valid = base_snapshot && result_snapshot
  archive_acceptance_transition_valid = base_snapshot && result_snapshot
  archive_touched_spec_paths = []
  if proposal["schema"] == "arkdeck-behavior" && base_snapshot && result_snapshot
    delta_sources = Dir.glob(archive_root.join("specs/**/*.md").to_s).sort.map do |delta_path|
      { "path" => relative(delta_path), "text" => File.read(delta_path) }
    end
    archive_overlay = build_behavior_overlay(
      delta_sources: delta_sources,
      baseline_requirement_acceptance: base_snapshot["requirement_acceptance"],
      baseline_acceptance_owner: base_snapshot["acceptance_owner"],
      baseline_requirement_paths: base_snapshot["requirements"].transform_values { |record| record["path"] },
      errors: errors,
      subject: "archive #{relative(archive_root)} behavior overlay"
    )
    expected_requirements = apply_behavior_overlay_to_snapshot(base_snapshot, archive_overlay)
    touched_paths = archive_overlay["records"].values.map { |record| record["target_path"] }.uniq.sort
    archive_touched_spec_paths = touched_paths
    same_file_set = base_snapshot["files"].keys.sort == result_snapshot["files"].keys.sort
    full_file_transition_valid = same_file_set && base_snapshot["files"].all? do |path, base_file|
      result_file = result_snapshot["files"][path]
      result_file && if touched_paths.include?(path)
                       base_file["non_requirement_sha256"] == result_file["non_requirement_sha256"]
                     else
                       base_file["sha256"] == result_file["sha256"]
                     end
    end
    archive_behavior_overlay_valid = expected_requirements == result_snapshot["requirements"] && full_file_transition_valid

    base_cases_source = git_file_content(lock["base_revision"], "openspec/verification/acceptance-cases.yaml")
    result_cases_source = git_file_content(result_revision, "openspec/verification/acceptance-cases.yaml")
    result_index_source = git_file_content(result_revision, "openspec/verification/acceptance-index.txt")
    local_cases_path = archive_root.join("acceptance-cases.yaml")
    if base_cases_source && result_cases_source && result_index_source && local_cases_path.file?
      base_cases_doc = YAML.safe_load(base_cases_source, aliases: false) || {}
      result_cases_doc = YAML.safe_load(result_cases_source, aliases: false) || {}
      local_cases_doc = YAML.safe_load(local_cases_path.read, aliases: false) || {}
      expected_cases = Array(base_cases_doc["cases"]).to_h { |item| [item["acceptance_id"], item.dup] }
      acceptance_target_paths = {}
      archive_overlay["records"].each_value do |record|
        Array(record["scenarios"]).each { |acceptance_id| acceptance_target_paths[acceptance_id] = record["target_path"] }
      end
      Array(local_cases_doc["cases"]).each do |item|
        promoted = item.reject { |field, _value| field == "source_sha256" }
        promoted["expected_source"] = "#{acceptance_target_paths[item['acceptance_id']]}##{item['acceptance_id']}"
        expected_cases[item["acceptance_id"]] = promoted
      end
      result_cases = Array(result_cases_doc["cases"]).to_h { |item| [item["acceptance_id"], item] }
      base_metadata = base_cases_doc.reject { |field, _value| %w[registry status cases].include?(field) }
      result_metadata = result_cases_doc.reject { |field, _value| %w[registry status cases].include?(field) }
      result_index = result_index_source.lines(chomp: true).reject { |line| line.empty? || line.start_with?("#") }
      expected_index = result_snapshot["acceptance_owner"].keys.sort
      local_case_ids = Array(local_cases_doc["cases"]).map { |item| item["acceptance_id"] }.sort
      archive_acceptance_transition_valid = base_metadata == result_metadata &&
                                              local_case_ids == archive_overlay["touched_acceptance"].sort &&
                                              expected_cases == result_cases && result_index == expected_index
    else
      archive_acceptance_transition_valid = false
    end
  elsif proposal["schema"] == "arkdeck-platform" && base_snapshot && result_snapshot
    archive_behavior_overlay_valid = base_snapshot["files"] == result_snapshot["files"]
    archive_acceptance_transition_valid = %w[acceptance-cases.yaml acceptance-index.txt].all? do |name|
      path = "openspec/verification/#{name}"
      git_file_sha256(lock["base_revision"], path) == git_file_sha256(result_revision, path)
    end
  end
  errors << "archive #{relative(archive_root)} result current specs are not exactly predecessor baseline + approved transition" unless archive_behavior_overlay_valid
  errors << "archive #{relative(archive_root)} result Core acceptance registry/index do not equal the approved transition" unless archive_acceptance_transition_valid
  source_change_directory = archive_root.basename.to_s.sub(/\A\d{4}-\d{2}-\d{2}-/, "")
  source_change_root_relative = "openspec/changes/#{source_change_directory}"
  archive_root_relative = relative(archive_root)
  live_verification_result_relative = "#{source_change_root_relative}/verification-result.json"
  verification_metadata_diff = git_diff_entries(verification_revision, source_tree_revision) || []
  expected_verification_metadata_diff = [{ "status" => "A", "path" => live_verification_result_relative }]
  if verification_approval_path
    expected_verification_metadata_diff << { "status" => "A", "path" => relative(verification_approval_path) }
  end
  expected_verification_metadata_diff.sort_by! { |entry| entry["path"] }
  verification_source_tree_valid = verification_approval_path && verification_metadata_diff == expected_verification_metadata_diff &&
                                   git_file_sha256(source_tree_revision, live_verification_result_relative) == Digest::SHA256.file(verification_result_path).hexdigest &&
                                   git_file_sha256(source_tree_revision, relative(verification_approval_path)) == Digest::SHA256.file(verification_approval_path).hexdigest
  errors << "archive #{relative(archive_root)} verification source tree is not the exact metadata-only finalized result child" unless verification_source_tree_valid
  source_change_paths = git_tree_paths(source_tree_revision, source_change_root_relative) || []
  expected_moved_destinations = source_change_paths.map do |source_path|
    "#{archive_root_relative}/#{source_path.delete_prefix("#{source_change_root_relative}/")}" 
  end.sort
  pre_archive_destination = relative(pre_archive_path)
  move_file_set_valid = !source_change_paths.empty? &&
                        (staged_archive_paths || []).sort == (expected_moved_destinations + [pre_archive_destination]).uniq.sort &&
                        (git_tree_paths(result_revision, source_change_root_relative) || []).empty?
  move_hashes_valid = source_change_paths.each_with_index.all? do |source_path, index|
    destination = expected_moved_destinations[index]
    git_file_sha256(source_tree_revision, source_path) == git_file_sha256(result_revision, destination)
  end
  staging_diff_entries = git_diff_entries(source_tree_revision, result_revision) || []
  staging_diff_by_path = staging_diff_entries.to_h { |entry| [entry["path"], entry["status"]] }
  staging_diff_unique = staging_diff_by_path.length == staging_diff_entries.length
  required_staging_changes = {}
  source_change_paths.each { |path| required_staging_changes[path] = "D" }
  (expected_moved_destinations + [pre_archive_destination]).each { |path| required_staging_changes[path] = "A" }
  allowed_staging_changes = required_staging_changes.dup
  if pre_archive_approval && approval_paths[pre_archive_approval["approvalId"]]
    pre_archive_approval_relative = relative(approval_paths[pre_archive_approval["approvalId"]])
    allowed_staging_changes[pre_archive_approval_relative] = "A"
    required_staging_changes[pre_archive_approval_relative] = "A"
  end
  if proposal["schema"] == "arkdeck-behavior"
    archive_touched_spec_paths.each { |path| allowed_staging_changes[path] = "M" }
    {
      "openspec/verification/acceptance-cases.yaml" => "M",
      "openspec/verification/acceptance-index.txt" => "M",
      "openspec/config.yaml" => "M",
      "openspec/verification/core-conformance.yaml" => "M",
      "openspec/verification/traceability.md" => "M",
      "openspec/platforms/PLATFORM-PROFILES.lock.yaml" => "M",
      result_baseline_relative => "A",
      archive_manifest_relative => "A"
    }.each { |path, status_code| allowed_staging_changes[path] = status_code }
    archive_touched_spec_paths.each { |path| required_staging_changes[path] = "M" }
    required_staging_changes["openspec/config.yaml"] = "M"
    required_staging_changes["openspec/verification/core-conformance.yaml"] = "M"
    required_staging_changes[result_baseline_relative] = "A"
    required_staging_changes[archive_manifest_relative] = "A"
  end
  platform_history_changes = staging_diff_entries.select do |entry|
    entry["path"].to_s.match?(/\Aopenspec\/platforms\/history\/PLATFORM-PROFILES-[A-Za-z0-9._-]+\.lock\.yaml\z/)
  end
  platform_history_valid = platform_history_changes.length <= 1 && platform_history_changes.all? do |entry|
    entry["status"] == "A" &&
      staging_diff_by_path["openspec/platforms/PLATFORM-PROFILES.lock.yaml"] == "M" &&
      git_file_sha256(result_revision, entry["path"]) == git_file_sha256(source_tree_revision, "openspec/platforms/PLATFORM-PROFILES.lock.yaml")
  end
  platform_history_changes.each { |entry| allowed_staging_changes[entry["path"]] = "A" }
  staging_paths_allowed = staging_diff_entries.all? do |entry|
    allowed_staging_changes[entry["path"]] == entry["status"]
  end
  required_staging_present = required_staging_changes.all? do |path, status_code|
    staging_diff_by_path[path] == status_code
  end
  archive_staging_transition_valid = move_file_set_valid && move_hashes_valid && staging_diff_unique &&
                                     platform_history_valid && staging_paths_allowed && required_staging_present
  errors << "archive #{relative(archive_root)} staging diff is not the exact approved sync/move transition" unless archive_staging_transition_valid
  valid_shape = lock["status"] == "archived" && lock["change_id"] == proposal["id"] && lock["revision"] == proposal["revision"] &&
                source_change_lock.file? && lock["source_change_lock_sha256"] == Digest::SHA256.file(source_change_lock).hexdigest && pre_archive_valid &&
                baseline_contained && archive_baseline_integrity && result_baseline.file? && lock.dig("result_core_baseline", "sha256") == Digest::SHA256.file(result_baseline).hexdigest &&
                lock.dig("result_core_baseline", "id") == result_baseline_doc["baseline"] && result_baseline_doc["status"] == "accepted" &&
                staged_archive_exact && verification_source_tree_valid && archive_staging_transition_valid && archive_behavior_overlay_valid && archive_acceptance_transition_valid &&
                historical_platform_valid && historical_conformance_valid &&
                git_commit?(lock["base_revision"]) && git_commit?(verification_revision) && git_commit?(source_tree_revision) && git_commit?(lock["result_revision"]) &&
                git_ancestor?(lock["base_revision"], verification_revision) && git_ancestor?(verification_revision, source_tree_revision) &&
                git_ancestor?(source_tree_revision, lock["result_revision"]) && git_ancestor?(lock["result_revision"], git_head_revision)
  errors << "archive #{relative(archive_root)} lock does not bind its approved source/result" unless valid_shape
  change_approval = approvals[source_change_lock_doc["approval_id"]]
  valid_change_approval = source_change_lock.file? && change_approval && source_change_lock_doc["status"] == "approved" &&
                          source_change_lock_doc["change_id"] == proposal["id"] && source_change_lock_doc["revision"] == proposal["revision"] &&
                          change_approval["subjectType"] == "change" && change_approval["subjectId"] == proposal["id"] &&
                          change_approval["subjectRevision"] == proposal["revision"] &&
                          change_approval["subjectSha256"] == Digest::SHA256.file(source_change_lock).hexdigest &&
                          change_approval["baseRevision"] == lock["base_revision"] && change_approval["decision"] == "approved" &&
                          externally_verified?(approval_paths[change_approval["approvalId"]], source_change_lock, change_approval, trusted_verifiers)
  errors << "archive #{relative(archive_root)} source change approval is invalid" unless valid_change_approval
  valid_verification_approval = verification_result["changeId"] == proposal["id"] &&
                                verification_result["changeRevision"] == proposal["revision"] &&
                                verification_result["status"] == "passed" &&
                                verification_result["changeLockSha256"] == Digest::SHA256.file(source_change_lock).hexdigest &&
                                verification_result["verificationPlanSha256"] == Digest::SHA256.file(verification_path).hexdigest &&
                                verification_result["resultRevision"] == verification_revision &&
                                verification_approval && verification_approval["subjectType"] == "changeVerification" &&
                                verification_approval["subjectId"] == verification_result["verificationId"] &&
                                verification_approval["subjectRevision"] == proposal["revision"] &&
                                verification_approval["subjectSha256"] == Digest::SHA256.file(verification_result_path).hexdigest &&
                                verification_approval["baseRevision"] == verification_result["resultRevision"] &&
                                verification_approval["decision"] == "approved" &&
                                externally_verified?(approval_paths[verification_approval["approvalId"]], verification_result_path, verification_approval, trusted_verifiers)
  errors << "archive #{relative(archive_root)} source verification approval is invalid" unless valid_verification_approval

  archive_task_packets = {}
  archive_task_packet_paths = {}
  Dir.glob(archive_root.join("task-packets/*.json")).sort.each do |packet_path_string|
    packet_path = Pathname.new(packet_path_string)
    packet = JSON.parse(packet_path.read)
    task_id = packet["taskId"]
    packet_contract = versioned_schemas["https://arkdeck.dev/schemas/task-packet-#{packet['schemaVersion']}.json"]
    if packet_contract
      missing = packet_contract.fetch("required") - packet.keys
      extra = packet.keys - packet_contract.fetch("properties").keys
      errors << "archived Task packet #{relative(packet_path)} missing #{missing.join(', ')}" unless missing.empty?
      errors << "archived Task packet #{relative(packet_path)} has unknown fields #{extra.join(', ')}" unless extra.empty?
    else
      errors << "archived Task packet #{relative(packet_path)} references an unavailable versioned schema"
    end
    errors << "archived Task packet filename/id mismatch: #{relative(packet_path)}" unless File.basename(packet_path, ".json") == task_id
    errors << "archive #{relative(archive_root)} has duplicate Task packet #{task_id}" if archive_task_packets.key?(task_id)
    archive_task_packets[task_id] = packet
    archive_task_packet_paths[task_id] = packet_path
    errors << "archived Task #{task_id} is not a frozen ready packet" unless packet["status"] == "ready" && packet["revision"] == 1
    errors << "archived Task #{task_id} belongs to another change" unless packet["changeId"] == proposal["id"] && packet["changeRevision"] == proposal["revision"]

    packet_approval = approvals[packet["approvalId"]]
    valid_packet_approval = packet_approval &&
                            packet_approval["subjectType"] == "taskPacket" && packet_approval["subjectId"] == task_id &&
                            packet_approval["subjectRevision"] == packet["revision"] &&
                            packet_approval["subjectSha256"] == Digest::SHA256.file(packet_path).hexdigest &&
                            packet_approval["baseRevision"] == packet["baseRevision"] && packet_approval["decision"] == "approved" &&
                            externally_verified?(approval_paths[packet_approval["approvalId"]], packet_path, packet_approval, trusted_verifiers)
    errors << "archived Task #{task_id} packet approval is invalid" unless valid_packet_approval
  end
  archive_tasks_path = archive_root.join("tasks.md")
  if archive_tasks_path.file?
    indexed_tasks = archive_tasks_path.read.scan(/\b(TASK-[A-Z0-9-]+)\b/).flatten.uniq
    errors << "archive #{relative(archive_root)} Task index differs from archived packets" unless indexed_tasks.sort == archive_task_packets.keys.sort
  else
    errors << "archive #{relative(archive_root)} has no Task index"
  end
  archive_scope = YAML.safe_load(scope_path.read, aliases: true) || {}
  archive_task_requirements = archive_task_packets.values.flat_map { |packet| Array(packet["requirementRefs"]) }.uniq.sort
  archive_task_acceptance = archive_task_packets.values.flat_map { |packet| Array(packet["acceptanceRefs"]) }.uniq.sort
  errors << "archive #{relative(archive_root)} scope identity/revision mismatch" unless archive_scope["change_id"] == proposal["id"] && archive_scope["revision"] == proposal["revision"]
  errors << "archive #{relative(archive_root)} Task Requirement union differs from immutable scope" unless archive_task_requirements == Array(archive_scope["requirements"]).sort
  errors << "archive #{relative(archive_root)} Task Acceptance union differs from immutable scope" unless archive_task_acceptance == Array(archive_scope["acceptance"]).sort

  archive_claims = {}
  archive_claim_paths = {}
  archive_claim_keys = {}
  archive_claim_owners = {}
  archive_claim_attestation_ids = {}
  Dir.glob(archive_root.join("evidence/runs/**/claim.json")).sort.each do |claim_path_string|
    claim_path = Pathname.new(claim_path_string)
    claim = JSON.parse(claim_path.read)
    claim_contract = versioned_schemas["https://arkdeck.dev/schemas/task-claim-#{claim['schemaVersion']}.json"]
    if claim_contract
      missing = claim_contract.fetch("required") - claim.keys
      extra = claim.keys - claim_contract.fetch("properties").keys
      errors << "archived claim #{relative(claim_path)} missing #{missing.join(', ')}" unless missing.empty?
      errors << "archived claim #{relative(claim_path)} has unknown fields #{extra.join(', ')}" unless extra.empty?
    else
      errors << "archived claim #{relative(claim_path)} references an unavailable versioned schema"
    end
    errors << "archive #{relative(archive_root)} has duplicate claim #{claim['claimId']}" if archive_claims.key?(claim["claimId"])
    claim_key = [claim["taskId"], claim["attempt"]]
    errors << "archive #{relative(archive_root)} has duplicate claim attempt #{claim_key.join('/')}" if archive_claim_keys.key?(claim_key)
    archive_claim_keys[claim_key] = claim["claimId"]
    archive_claims[claim["claimId"]] = claim
    archive_claim_paths[claim["claimId"]] = claim_path

    packet = archive_task_packets[claim["taskId"]]
    packet_path = archive_task_packet_paths[claim["taskId"]]
    exact_claim = packet && packet_path && claim["status"] == "claimed" &&
                  claim["taskPacketSha256"] == Digest::SHA256.file(packet_path).hexdigest &&
                  claim["taskRevision"] == packet["revision"] && claim["approvalId"] == packet["approvalId"] &&
                  claim["changeId"] == packet["changeId"] && claim["changeRevision"] == packet["changeRevision"] &&
                  claim["baseRevision"] == packet["baseRevision"] && claim["platform"] == packet["platform"]
    errors << "archived claim #{relative(claim_path)} does not exactly bind its Task packet" unless exact_claim

    owner_path = claim_path.parent.join("claim-owner-attestation.json")
    if !owner_path.file?
      errors << "archived claim #{relative(claim_path)} has no protected owner attestation"
      next
    end
    owner = JSON.parse(owner_path.read)
    owner_contract = versioned_schemas["https://arkdeck.dev/schemas/claim-owner-attestation-#{owner['schemaVersion']}.json"] || claim_owner_schema
    owner_missing = owner_contract.fetch("required") - owner.keys
    owner_extra = owner.keys - owner_contract.fetch("properties").keys
    errors << "archived claim owner #{relative(owner_path)} missing #{owner_missing.join(', ')}" unless owner_missing.empty?
    errors << "archived claim owner #{relative(owner_path)} has unknown fields #{owner_extra.join(', ')}" unless owner_extra.empty?
    errors << "archive #{relative(archive_root)} has duplicate claim owner attestation #{owner['attestationId']}" if archive_claim_attestation_ids.key?(owner["attestationId"])
    archive_claim_attestation_ids[owner["attestationId"]] = relative(owner_path)
    valid_owner = owner["subjectType"] == "taskClaim" && owner["claimId"] == claim["claimId"] &&
                  owner["claimSha256"] == Digest::SHA256.file(claim_path).hexdigest && owner["taskId"] == claim["taskId"] &&
                  owner["attempt"] == claim["attempt"] && owner["claimantKind"] == claim["claimantKind"] &&
                  owner["claimedBy"] == claim["claimedBy"] && owner["claimedAt"] == claim["claimedAt"] &&
                  owner["leaseExpiresAt"] == claim["leaseExpiresAt"] &&
                  externally_verified?(owner_path, claim_path, owner, trusted_verifiers)
    errors << "archived claim #{relative(claim_path)} owner attestation is not exact or externally verified" unless valid_owner
    archive_claim_owners[claim["claimId"]] = owner if valid_owner
  end

  archive_runs_by_claim = {}
  archive_run_ids = {}
  archive_run_paths_by_id = {}
  archive_valid_done_runs = {}
  archive_done_tasks = Hash.new { |hash, key| hash[key] = [] }
  archive_superseded_tasks = {}
  archive_task_supersession_by_replacement = {}
  archive_run_attestation_ids = {}
  Dir.glob(archive_root.join("evidence/runs/**/run.json")).sort.each do |run_path_string|
    run_path = Pathname.new(run_path_string)
    run = JSON.parse(run_path.read)
    run_contract = versioned_schemas["https://arkdeck.dev/schemas/task-run-#{run['schemaVersion']}.json"]
    if run_contract
      missing = run_contract.fetch("required") - run.keys
      extra = run.keys - run_contract.fetch("properties").keys
      errors << "archived run #{relative(run_path)} missing #{missing.join(', ')}" unless missing.empty?
      errors << "archived run #{relative(run_path)} has unknown fields #{extra.join(', ')}" unless extra.empty?
    else
      errors << "archived run #{relative(run_path)} references an unavailable versioned schema"
    end
    errors << "archive #{relative(archive_root)} has duplicate run ID #{run['runId']}" if archive_run_ids.key?(run["runId"])
    archive_run_ids[run["runId"]] = relative(run_path)
    archive_run_paths_by_id[run["runId"]] = run_path
    errors << "archived claim #{run['claimId']} has more than one run" if archive_runs_by_claim.key?(run["claimId"])
    archive_runs_by_claim[run["claimId"]] = run

    claim = archive_claims[run["claimId"]]
    packet = archive_task_packets[run["taskId"]]
    packet_path = archive_task_packet_paths[run["taskId"]]
    exact_run = claim && packet && packet_path && run["taskId"] == claim["taskId"] &&
                run["taskRevision"] == claim["taskRevision"] && run["taskRevision"] == packet["revision"] &&
                run["attempt"] == claim["attempt"] &&
                run["taskPacketSha256"] == claim["taskPacketSha256"] &&
                run["taskPacketSha256"] == Digest::SHA256.file(packet_path).hexdigest &&
                run["changeId"] == packet["changeId"] && run["changeRevision"] == packet["changeRevision"] &&
                run["baseRevision"] == claim["baseRevision"] && run["platform"] == packet["platform"] &&
                run["executedBy"] == claim["claimedBy"]
    errors << "archived run #{relative(run_path)} does not exactly bind its claim and Task packet" unless exact_run

    owner_path = run_path.parent.join("run-owner-attestation.json")
    valid_run_owner = false
    if !owner_path.file?
      errors << "archived run #{relative(run_path)} has no protected owner attestation"
    else
      owner = JSON.parse(owner_path.read)
      owner_contract = versioned_schemas["https://arkdeck.dev/schemas/run-owner-attestation-#{owner['schemaVersion']}.json"] || run_owner_schema
      owner_missing = owner_contract.fetch("required") - owner.keys
      owner_extra = owner.keys - owner_contract.fetch("properties").keys
      errors << "archived run owner #{relative(owner_path)} missing #{owner_missing.join(', ')}" unless owner_missing.empty?
      errors << "archived run owner #{relative(owner_path)} has unknown fields #{owner_extra.join(', ')}" unless owner_extra.empty?
      errors << "archive #{relative(archive_root)} has duplicate run owner attestation #{owner['attestationId']}" if archive_run_attestation_ids.key?(owner["attestationId"])
      archive_run_attestation_ids[owner["attestationId"]] = relative(owner_path)
      claim_owner = claim && archive_claim_owners[claim["claimId"]]
      valid_run_owner = claim_owner && owner["subjectType"] == "taskRunLease" &&
                        owner["claimAttestationId"] == claim_owner["attestationId"] && owner["claimId"] == run["claimId"] &&
                        owner["runId"] == run["runId"] && owner["runSha256"] == Digest::SHA256.file(run_path).hexdigest &&
                        owner["taskId"] == run["taskId"] && owner["attempt"] == run["attempt"] &&
                        owner["executedBy"] == run["executedBy"] && owner["finalizedAt"] == run["endedAt"] &&
                        externally_verified?(owner_path, run_path, owner, trusted_verifiers)
      errors << "archived run #{relative(run_path)} owner attestation is not exact or externally verified" unless valid_run_owner
    end

    if run["status"] == "done"
      run_approval = approvals[run["approvalId"]]
      valid_run_approval = run_approval && run_approval["subjectType"] == "taskRun" &&
                           run_approval["subjectId"] == run["runId"] && run_approval["subjectRevision"] == run["attempt"] &&
                           run_approval["subjectSha256"] == Digest::SHA256.file(run_path).hexdigest &&
                           run_approval["baseRevision"] == run["baseRevision"] && run_approval["decision"] == "approved" &&
                           externally_verified?(approval_paths[run_approval["approvalId"]], run_path, run_approval, trusted_verifiers)
      errors << "archived done run #{relative(run_path)} lacks externally verified result approval" unless valid_run_approval
      result_in_archive = git_ancestor?(run["resultRevision"], verification_revision)
      result_descends_from_base = git_ancestor?(run["baseRevision"], run["resultRevision"])
      errors << "archived done run #{relative(run_path)} result is not an ancestor of the archive result" unless result_in_archive
      errors << "archived done run #{relative(run_path)} result is not descended from its base" unless result_descends_from_base
      valid_archived_done_run = exact_run && valid_run_owner && valid_run_approval && result_in_archive && result_descends_from_base
      archive_done_tasks[run["taskId"]] << run["runId"] if valid_archived_done_run
      archive_valid_done_runs[run["runId"]] = run if valid_archived_done_run
      if valid_archived_done_run && pre_archive_valid && valid_shape && valid_verification_approval &&
         packet && packet["executionEnvironment"] == "controlledHardwareLab" && run["realDeviceDispatchCount"].to_i.positive?
        lab_path = run_path.parent.join("lab-execution-authorization.json")
        plan_path = run_path.parent.join("lab-execution-plan.json")
        if lab_path.file? && plan_path.file?
          errors << "archived hardware provenance reuses run #{run['runId']}" if archived_hardware_provenance.key?(run["runId"])
          archived_hardware_provenance[run["runId"]] = {
            "run" => run,
            "task" => packet,
            "lab" => JSON.parse(lab_path.read),
            "plan" => JSON.parse(plan_path.read),
            "realExecutionRecords" => Array(run["workflowExecutionRecords"]).select do |record|
              record["disposition"] == "executed" && record["bindingRequirement"] == "confirmedDevice" && record["effect"] != "hostOnly"
            end,
            "platformContext" => platform_context_for_task(run["resultRevision"], packet),
            "caseDefinitions" => archive_case_definitions
          }
        else
          errors << "archived controlled-lab run #{run['runId']} lacks its immutable plan/authorization provenance bundle"
        end
      end
    elsif run["status"] == "superseded" && exact_run && valid_run_owner
      replacement = archive_task_packets[run["supersededByTaskId"]]
      replacement_path = archive_task_packet_paths[run["supersededByTaskId"]]
      valid_supersession = valid_task_supersession?(
        run: run,
        run_path: run_path,
        original: packet,
        replacement: replacement,
        replacement_path: replacement_path,
        approvals: approvals,
        approval_paths: approval_paths,
        verifiers: trusted_verifiers
      )
      errors << "archived superseded run #{relative(run_path)} lacks an exact approved Ready replacement with preserved scope" unless valid_supersession
      if valid_supersession
        archive_superseded_tasks[run["taskId"]] = true
        replacement_id = run["supersededByTaskId"]
        errors << "archived replacement Task #{replacement_id} is authorized by more than one superseded run" if archive_task_supersession_by_replacement.key?(replacement_id)
        archive_task_supersession_by_replacement[replacement_id] = {
          "runId" => run["runId"],
          "approvalId" => run["supersessionApprovalId"],
          "approvedAt" => approvals.dig(run["supersessionApprovalId"], "approvedAt")
        }
      end
    end
  end

  archive_claims.each_value do |claim|
    authorization = archive_task_supersession_by_replacement[claim["taskId"]]
    if authorization
      begin
        claimed_at = DateTime.iso8601(claim.fetch("claimedAt"))
        approved_at = DateTime.iso8601(authorization.fetch("approvedAt"))
        chronology_valid = approved_at < claimed_at
      rescue KeyError, Date::Error, TypeError
        chronology_valid = false
      end
      exact = claim["supersededRunId"] == authorization["runId"] &&
              claim["taskSupersessionApprovalId"] == authorization["approvalId"]
      errors << "archived replacement claim #{claim['claimId']} does not bind or strictly postdate its taskSupersession approval" unless exact && chronology_valid
    elsif !claim["supersededRunId"].nil? || !claim["taskSupersessionApprovalId"].nil?
      errors << "archived ordinary claim #{claim['claimId']} carries an unresolved taskSupersession authorization"
    end
  end

  missing_terminal_claims = archive_claims.keys - archive_runs_by_claim.keys
  errors << "archive #{relative(archive_root)} has claims without terminal runs: #{missing_terminal_claims.sort.join(', ')}" unless missing_terminal_claims.empty?
  conflicting_task_outcomes = archive_done_tasks.keys & archive_superseded_tasks.keys
  errors << "archive #{relative(archive_root)} has Tasks that are both done and superseded: #{conflicting_task_outcomes.sort.join(', ')}" unless conflicting_task_outcomes.empty?
  archive_active_tasks = archive_task_packets.keys - archive_superseded_tasks.keys
  errors << "archive #{relative(archive_root)} has no active Task packets" if archive_active_tasks.empty?
  unfinished_tasks = archive_active_tasks.reject { |task_id| archive_done_tasks[task_id].length == 1 }
  errors << "archive #{relative(archive_root)} contains unfinished or multiply-completed Task runs: #{unfinished_tasks.sort.join(', ')}" unless unfinished_tasks.empty?
  archive_task_run_entries = Array(verification_result["taskRuns"])
  archive_task_run_task_ids = archive_task_run_entries.map { |entry| entry["taskId"] }
  errors << "archive #{relative(archive_root)} verification result does not exactly cover active Tasks" unless
    archive_task_run_task_ids.sort == archive_active_tasks.sort && archive_task_run_task_ids.uniq.length == archive_task_run_task_ids.length
  archive_bound_runs = {}
  archive_task_run_entries.each do |entry|
    run = archive_valid_done_runs[entry["runId"]]
    run_path = archive_run_paths_by_id[entry["runId"]]
    exact = run && run_path && run["taskId"] == entry["taskId"] && run["changeId"] == proposal["id"] &&
            entry["runSha256"] == Digest::SHA256.file(run_path).hexdigest &&
            entry["resultRevision"] == run["resultRevision"] && git_ancestor?(run["resultRevision"], verification_revision)
    errors << "archive #{relative(archive_root)} verification result has an invalid Task run binding for #{entry['taskId']}" unless exact
    archive_bound_runs[entry["runId"]] = run if exact
  end
  archive_change_base_revision = change_approval && change_approval["baseRevision"]
  archive_aggregate_base_exact = !archive_change_base_revision.to_s.empty? && archive_active_tasks.all? do |task_id|
    archive_task_packets.dig(task_id, "baseRevision") == archive_change_base_revision
  end
  errors << "archive #{relative(archive_root)} active Tasks do not share the exact change-approval base" unless archive_aggregate_base_exact

  archive_provenance_files = {}
  add_archived_provenance = lambda do |source_path, archived_path|
    sha256 = git_file_sha256(result_revision, relative(archived_path))
    archive_provenance_files[source_path] = sha256 if sha256
  end
  add_external_provenance = lambda do |path|
    archive_provenance_files[relative(path)] = Digest::SHA256.file(path).hexdigest if path && Pathname.new(path).file?
  end
  source_path_for_archive = lambda do |path|
    suffix = Pathname.new(path).relative_path_from(archive_root).to_s
    "#{source_change_root_relative}/#{suffix}"
  end
  add_archived_provenance.call(source_path_for_archive.call(archive_tasks_path), archive_tasks_path)
  archive_task_packet_paths.each_value do |packet_path|
    add_archived_provenance.call(source_path_for_archive.call(packet_path), packet_path)
  end
  archive_summary_path = archive_root.join("evidence/summary.md")
  add_archived_provenance.call(source_path_for_archive.call(archive_summary_path), archive_summary_path) if archive_summary_path.file?
  archive_barrier_path = archive_root.join("supersession-barrier-attestation.json")
  add_archived_provenance.call(source_path_for_archive.call(archive_barrier_path), archive_barrier_path) if archive_barrier_path.file?

  archive_approval_ids = [source_change_lock_doc["approval_id"]]
  archive_claims.each do |claim_id, claim|
    claim_path = archive_claim_paths[claim_id]
    if claim_path
      add_archived_provenance.call(source_path_for_archive.call(claim_path), claim_path)
      %w[
        claim-owner-attestation.json
        resource-identity-attestation.json
        lab-execution-plan.json
        lab-execution-authorization.json
      ].each do |name|
        sidecar_path = claim_path.parent.join(name)
        add_archived_provenance.call(source_path_for_archive.call(sidecar_path), sidecar_path) if sidecar_path.file?
      end
      lab_path = claim_path.parent.join("lab-execution-authorization.json")
      archive_approval_ids << JSON.parse(lab_path.read)["approvalId"] if lab_path.file?
    end
    archive_approval_ids << claim["approvalId"]
  end
  archive_runs_by_claim.each_value do |run|
    run_path = archive_run_paths_by_id[run["runId"]]
    if run_path
      add_archived_provenance.call(source_path_for_archive.call(run_path), run_path)
      owner_path = run_path.parent.join("run-owner-attestation.json")
      add_archived_provenance.call(source_path_for_archive.call(owner_path), owner_path) if owner_path.file?
    end
    archive_approval_ids.concat([run["approvalId"], run["supersessionApprovalId"]])
    Array(run["evidence"]).each { |item| archive_approval_ids << item["verificationRef"] }
    Array(run["acceptanceResults"]).flat_map { |item| Array(item["hardwareMatrixRefs"]) }.uniq.each do |evidence_id|
      evidence_path = hardware_evidence_paths[evidence_id]
      record = approved_hardware[evidence_id]
      if evidence_path && record
        add_external_provenance.call(evidence_path)
        archive_approval_ids << record["approvalId"]
      end
    end
  end
  archive_task_packets.each_value { |packet| archive_approval_ids << packet["approvalId"] }
  historical_prerequisite_specs = [
    {
      "path" => "openspec/governance/trust-policy.yaml",
      "subjectType" => "trustPolicy",
      "idField" => "policy",
      "accepted" => ->(document) { document["status"] == "accepted" && document["execution_gate"] == "open" }
    },
    {
      "path" => "openspec/integrations/INTEGRATION-PROFILES.lock.yaml",
      "subjectType" => "integrationLock",
      "idField" => "lock",
      "accepted" => ->(document) { document["status"] == "accepted" && document["execution_gate"] == "open" }
    },
    {
      "path" => "openspec/platforms/PLATFORM-PROFILES.lock.yaml",
      "subjectType" => "platformLock",
      "idField" => "lock",
      "accepted" => ->(document) { document["status"] == "accepted" && document["execution_gate"] == "open" }
    },
    {
      "path" => "openspec/verification/core-conformance.yaml",
      "subjectType" => "conformanceSuite",
      "idField" => "suite",
      "accepted" => ->(document) { document["status"] == "accepted" && document["execution_gate"] == "open" }
    }
  ]
  baseline_versions = archive_task_packets.values.map { |packet| packet.dig("coreBaseline", "version") }.compact.uniq
  if baseline_versions.length == 1
    historical_prerequisite_specs << {
      "path" => "openspec/baselines/CORE-#{baseline_versions.first}.lock.yaml",
      "subjectType" => "baseline",
      "idField" => "baseline",
      "accepted" => lambda do |document|
        document["status"] == "accepted" && document.dig("ratification", "execution_gate") == "open"
      end
    }
  else
    errors << "archive #{relative(archive_root)} Tasks do not share one pinned Core baseline version"
  end
  historical_prerequisites = {}
  historical_prerequisite_specs.each do |specification|
    path = specification["path"]
    source = git_file_content(verification_revision, path)
    document = {}
    begin
      document = YAML.safe_load(source, permitted_classes: [Date, Time], aliases: false) || {}
    rescue Psych::Exception, TypeError
      errors << "archive #{relative(archive_root)} cannot parse historical prerequisite #{path}"
    end
    approval_id = document.dig("ratification", "approval_ref")
    prerequisite_approval = approvals[approval_id]
    exact_prerequisite = source && specification["accepted"].call(document) && valid_historical_approval?(
      source: source,
      subject_name: File.basename(path),
      document: document,
      approval: prerequisite_approval,
      approval_path: prerequisite_approval && approval_paths[prerequisite_approval["approvalId"]],
      subject_type: specification["subjectType"],
      subject_id: document[specification["idField"]],
      result_revision: verification_revision,
      verifiers: trusted_verifiers
    )
    errors << "archive #{relative(archive_root)} historical prerequisite #{path} is not exact, accepted and externally verified" unless exact_prerequisite
    historical_prerequisites[path] = { "source" => source, "document" => document, "valid" => exact_prerequisite }
    archive_approval_ids << approval_id
  end

  historical_baseline = historical_prerequisites["openspec/baselines/CORE-#{baseline_versions.first}.lock.yaml"]
  historical_integration = historical_prerequisites["openspec/integrations/INTEGRATION-PROFILES.lock.yaml"]
  historical_platform = historical_prerequisites["openspec/platforms/PLATFORM-PROFILES.lock.yaml"]
  historical_conformance = historical_prerequisites["openspec/verification/core-conformance.yaml"]
  archive_task_packets.each_value do |packet|
    exact_core_pin = historical_baseline && historical_baseline["valid"] &&
                     "#{packet.dig('coreBaseline', 'id')}-#{packet.dig('coreBaseline', 'version')}" == historical_baseline.dig("document", "baseline") &&
                     packet.dig("coreBaseline", "sha256") == Digest::SHA256.hexdigest(historical_baseline["source"].b)
    exact_conformance_pin = historical_conformance && historical_conformance["valid"] &&
                            packet.dig("conformanceSuite", "id") == historical_conformance.dig("document", "suite") &&
                            packet.dig("conformanceSuite", "sha256") == Digest::SHA256.hexdigest(historical_conformance["source"].b)
    platform_entry = historical_platform && Array(historical_platform.dig("document", "profiles")).find do |entry|
      entry["id"] == packet.dig("platformProfile", "id") && entry["version"] == packet.dig("platformProfile", "version")
    end
    exact_platform_pin = platform_entry &&
                         packet["platform"] == platform_entry["platform"] &&
                         packet.dig("platformProfile", "sha256") == platform_entry["profile_sha256"] &&
                         git_file_sha256(verification_revision, platform_entry["profile_path"].to_s) == platform_entry["profile_sha256"]
    integration_entries = historical_integration ? Array(historical_integration.dig("document", "profiles")) : []
    exact_integration_pins = Array(packet["integrationProfiles"]).all? do |pin|
      entry = integration_entries.find { |candidate| candidate["id"] == pin["id"] && candidate["version"] == pin["version"] }
      entry && pin["sha256"] == entry["sha256"] &&
        git_file_sha256(verification_revision, entry["path"].to_s) == entry["sha256"]
    end
    unless exact_core_pin && exact_conformance_pin && exact_platform_pin && exact_integration_pins
      errors << "archive #{relative(archive_root)} Task #{packet['taskId']} pins do not resolve exactly in verification_revision"
    end
  end
  archive_approval_ids.compact.uniq.each do |approval_id|
    add_external_provenance.call(approval_paths[approval_id]) if approval_paths[approval_id]
  end
  archive_aggregate_valid = archive_aggregate_base_exact && validate_task_result_aggregate(
    errors: errors,
    subject: "archive #{relative(archive_root)} verification result",
    base_revision: archive_change_base_revision,
    result_revision: verification_revision,
    runs: archive_bound_runs.values,
    provenance_files: archive_provenance_files
  )
  errors << "archive #{relative(archive_root)} verification aggregate provenance is invalid" unless archive_aggregate_valid
  active_archive_requirements = archive_active_tasks.flat_map { |task_id| Array(archive_task_packets.dig(task_id, "requirementRefs")) }.uniq.sort
  active_archive_acceptance = archive_active_tasks.flat_map { |task_id| Array(archive_task_packets.dig(task_id, "acceptanceRefs")) }.uniq.sort
  errors << "archive #{relative(archive_root)} active Task Requirement union differs from immutable scope" unless active_archive_requirements == Array(archive_scope["requirements"]).sort
  errors << "archive #{relative(archive_root)} active Task Acceptance union differs from immutable scope" unless active_archive_acceptance == Array(archive_scope["acceptance"]).sort
  begin
    latest_archived_run = archive_runs_by_claim.values.map { |run| DateTime.iso8601(run.fetch("endedAt")) }.max
    errors << "archive #{relative(archive_root)} pre-move semantic attestation predates a terminal run" unless pre_archive_validated_at && latest_archived_run && pre_archive_validated_at >= latest_archived_run
    verification_approved_at = DateTime.iso8601(verification_approval.fetch("approvedAt"))
    errors << "archive #{relative(archive_root)} pre-move semantic attestation predates change verification approval" unless pre_archive_validated_at && pre_archive_validated_at >= verification_approved_at
  rescue KeyError, Date::Error
    errors << "archive #{relative(archive_root)} has invalid pre-move/run/verification chronology"
  end

  baseline_approval = approvals[result_baseline_doc.dig("ratification", "approval_ref")]
  result_baseline_changed = git_file_sha256(source_tree_revision, result_baseline_relative) !=
                            git_file_sha256(result_revision, result_baseline_relative)
  baseline_approval_base_valid = baseline_approval && git_commit?(baseline_approval["baseRevision"]) &&
                                 git_ancestor?(baseline_approval["baseRevision"], result_revision) &&
                                 (!result_baseline_changed || baseline_approval["baseRevision"] == result_revision)
  valid_baseline_approval = result_baseline.file? && baseline_approval && baseline_approval["subjectType"] == "baseline" &&
                            baseline_approval["subjectId"] == result_baseline_doc["baseline"] &&
                            baseline_approval["subjectRevision"] == result_baseline_doc["revision"] &&
                            baseline_approval["subjectSha256"] == Digest::SHA256.file(result_baseline).hexdigest &&
                            baseline_approval_base_valid && baseline_approval["decision"] == "approved" &&
                            externally_verified?(approval_paths[baseline_approval["approvalId"]], result_baseline, baseline_approval, trusted_verifiers)
  errors << "archive #{relative(archive_root)} result baseline is not externally ratified" unless valid_baseline_approval
  approval = approvals[lock["approval_id"]]
  begin
    archive_approved_at = DateTime.iso8601(approval.fetch("approvedAt")) if approval
    verification_approved_at = DateTime.iso8601(verification_approval.fetch("approvedAt"))
    baseline_approved_at = DateTime.iso8601(baseline_approval.fetch("approvedAt"))
    change_approved_at = DateTime.iso8601(change_approval.fetch("approvedAt"))
    archive_prerequisite_times = [pre_archive_validated_at, pre_archive_approved_at, verification_approved_at, baseline_approved_at, change_approved_at]
    valid_archive_chronology = approval && archive_prerequisite_times.all? && archive_approved_at >= archive_prerequisite_times.max
    if (successor = effective_change_successors[proposal["id"]]) && archive_approved_at >= successor["approved_at"]
      errors << "superseded Change #{proposal['id']} was archived after successor #{successor['change_id']} became effective"
      valid_archive_chronology = false
    end
  rescue KeyError, Date::Error, NoMethodError
    valid_archive_chronology = false
  end
  valid_approval = approval && approval["subjectType"] == "archive" && approval["subjectId"] == proposal["id"] &&
                   approval["subjectRevision"] == proposal["revision"] && approval["subjectSha256"] == Digest::SHA256.file(archive_lock_path).hexdigest &&
                   approval["baseRevision"] == lock["result_revision"] && approval["decision"] == "approved" && valid_archive_chronology &&
                   externally_verified?(approval_paths[approval["approvalId"]], archive_lock_path, approval, trusted_verifiers)
  errors << "archive #{relative(archive_root)} has no externally verified archive approval" unless valid_approval

  publication_add_commits = git_path_add_commits(result_revision, git_head_revision, relative(archive_lock_path)) || []
  publication_revision = publication_add_commits.length == 1 ? publication_add_commits.first : nil
  publication_approval_ids = [lock["approval_id"], result_baseline_doc.dig("ratification", "approval_ref")]
  publication_approval_ids << historical_platform_doc.dig("ratification", "approval_ref")
  publication_approval_ids << historical_conformance_doc.dig("ratification", "approval_ref")
  publication_paths = [relative(archive_lock_path)]
  publication_approval_ids.compact.uniq.each do |approval_id|
    approval_path = approval_paths[approval_id]
    publication_paths << relative(approval_path) if approval_path && git_file_content(result_revision, relative(approval_path)).nil?
  end
  expected_publication_diff = publication_paths.uniq.sort.map { |path| { "status" => "A", "path" => path } }
  actual_publication_diff = publication_revision ? (git_diff_entries(result_revision, publication_revision) || []) : []
  publication_files_exact = publication_revision && publication_paths.uniq.all? do |path|
    current_path = ROOT.join(path)
    current_path.file? && git_file_sha256(publication_revision, path) == Digest::SHA256.file(current_path).hexdigest
  end
  publication_transition_valid = publication_revision && git_commit?(publication_revision) &&
                                 git_ancestor?(result_revision, publication_revision) && git_ancestor?(publication_revision, git_head_revision) &&
                                 actual_publication_diff == expected_publication_diff && publication_files_exact
  errors << "archive #{relative(archive_root)} publication commit is missing, ambiguous or contains non-metadata changes" unless publication_transition_valid
end

pending_archived_hardware.each do |evidence_id, record|
  validate_hardware_provenance.call(evidence_id, record, archived_hardware_provenance[record["taskRunId"]])
end

all_task_packet_paths = Dir.glob(ROOT.join("openspec/changes/**/task-packets/*.json")).map { |path| Pathname.new(path) }
global_task_identities = Hash.new { |hash, key| hash[key] = [] }
all_task_packet_paths.each do |packet_path|
  packet = JSON.parse(packet_path.read)
  global_task_identities[packet["taskId"]] << { "revision" => packet["revision"], "path" => relative(packet_path) }
end
global_task_identities.each do |task_id, entries|
  errors << "Task identity #{task_id} is reused across live/archive packets: #{entries.map { |entry| entry['path'] }.sort.join(', ')}" if entries.length > 1
end

all_claim_paths = Dir.glob(ROOT.join("openspec/changes/**/evidence/runs/**/claim.json")).map { |path| Pathname.new(path) }
global_claim_ids = Hash.new { |hash, key| hash[key] = [] }
global_task_attempts = Hash.new { |hash, key| hash[key] = [] }
all_claim_paths.each do |claim_path|
  claim = JSON.parse(claim_path.read)
  global_claim_ids[claim["claimId"]] << relative(claim_path)
  global_task_attempts[[claim["taskId"], claim["attempt"]]] << relative(claim_path)
end
global_claim_ids.each do |claim_id, paths|
  errors << "claim identity #{claim_id} is reused across live/archive history" if paths.length > 1
end
global_task_attempts.each do |(task_id, attempt), paths|
  errors << "Task attempt #{task_id}/#{attempt} is reused across live/archive history" if paths.length > 1
end

all_run_paths = Dir.glob(ROOT.join("openspec/changes/**/evidence/runs/**/run.json")).map { |path| Pathname.new(path) }
global_run_ids = Hash.new { |hash, key| hash[key] = [] }
global_runs_by_claim = Hash.new { |hash, key| hash[key] = [] }
all_run_paths.each do |run_path|
  run = JSON.parse(run_path.read)
  global_run_ids[run["runId"]] << relative(run_path)
  global_runs_by_claim[run["claimId"]] << relative(run_path)
end
global_run_ids.each do |run_id, paths|
  errors << "run identity #{run_id} is reused across live/archive history" if paths.length > 1
end
global_runs_by_claim.each do |claim_id, paths|
  errors << "claim #{claim_id} has multiple terminal runs across live/archive history" if paths.length > 1
end

global_attestation_ids = Hash.new { |hash, key| hash[key] = [] }
Dir.glob(ROOT.join("openspec/changes/**/*.json")).sort.each do |path|
  document = JSON.parse(File.read(path))
  next if document["attestationId"].to_s.empty?

  global_attestation_ids[document["attestationId"]] << relative(path)
end
global_attestation_ids.each do |attestation_id, paths|
  errors << "attestation identity #{attestation_id} is reused across live/archive history" if paths.length > 1
end

approvals.values.select { |approval| approval["decision"] == "approved" }.group_by do |approval|
  [approval["subjectType"], approval["subjectId"], approval["subjectRevision"]]
end.each do |identity, subject_approvals|
  hashes = subject_approvals.map { |approval| approval["subjectSha256"] }.uniq
  next if hashes.length == 1

  errors << "approved subject identity #{identity.join('/')} maps to multiple immutable hashes"
end

approvals.values.select { |approval| approval["subjectType"] == "taskPacket" && approval["decision"] == "approved" }.each do |approval|
  matches = all_task_packet_paths.select do |packet_path|
    packet = JSON.parse(packet_path.read)
    packet["taskId"] == approval["subjectId"] && packet["revision"] == approval["subjectRevision"] &&
      Digest::SHA256.file(packet_path).hexdigest == approval["subjectSha256"] && packet["baseRevision"] == approval["baseRevision"]
  end
  errors << "approved Task packet #{approval['subjectId']} was removed or rewritten" unless matches.length == 1
end

all_change_lock_paths = Dir.glob(ROOT.join("openspec/changes/**/change-lock.yaml")).map { |path| Pathname.new(path) }
approvals.values.select { |approval| approval["subjectType"] == "change" && approval["decision"] == "approved" }.each do |approval|
  matches = all_change_lock_paths.select do |lock_path|
    lock = YAML.safe_load(lock_path.read, aliases: false) || {}
    lock["change_id"] == approval["subjectId"] && lock["revision"] == approval["subjectRevision"] &&
      Digest::SHA256.file(lock_path).hexdigest == approval["subjectSha256"] && approval["subjectRevision"] == 1
  end
  errors << "approved Change #{approval['subjectId']} was removed, rewritten or illegally revisioned" unless matches.length == 1
end

current_identity_inventory = {}
add_identity = lambda do |kind, id, revision, sha256|
  key = [kind.to_s, id.to_s, revision.to_s]
  if key.any?(&:empty?) || !sha256.to_s.match?(/\A[a-f0-9]{64}\z/)
    errors << "immutable identity inventory contains an invalid #{key.join('/')} binding"
    next
  end
  if current_identity_inventory.key?(key) && current_identity_inventory[key] != sha256
    errors << "immutable identity #{key.join('/')} maps to multiple hashes in the current tree"
  else
    current_identity_inventory[key] = sha256
  end
end

all_task_packet_paths.each do |path|
  packet = JSON.parse(path.read)
  next unless packet["status"] == "ready"

  add_identity.call("taskPacket", packet["taskId"], packet["revision"], Digest::SHA256.file(path).hexdigest)
end
all_claim_paths.each do |path|
  claim = JSON.parse(path.read)
  add_identity.call("claim", claim["claimId"], claim["attempt"], Digest::SHA256.file(path).hexdigest)
end
all_run_paths.each do |path|
  run = JSON.parse(path.read)
  add_identity.call("run", run["runId"], run["attempt"], Digest::SHA256.file(path).hexdigest)
end
Dir.glob(ROOT.join("openspec/changes/**/*.json")).sort.each do |path|
  document = JSON.parse(File.read(path))
  next if document["attestationId"].to_s.empty?

  add_identity.call("attestation", document["attestationId"], document["schemaVersion"] || "1", Digest::SHA256.file(path).hexdigest)
end
approval_paths.each do |approval_id, path|
  approval = approvals[approval_id]
  add_identity.call("approval", approval_id, approval["subjectRevision"], Digest::SHA256.file(path).hexdigest)
  if approval["decision"] == "approved"
    add_identity.call(
      "approvedSubject",
      "#{approval['subjectType']}:#{approval['subjectId']}",
      approval["subjectRevision"],
      approval["subjectSha256"]
    )
  end
end
all_change_lock_paths.each do |path|
  lock = YAML.safe_load(path.read, aliases: false) || {}
  next unless lock["status"] == "approved"

  add_identity.call("changeLock", lock["change_id"], lock["revision"], Digest::SHA256.file(path).hexdigest)
end
Dir.glob(ROOT.join("openspec/changes/archive/*/archive-lock.yaml")).sort.each do |path|
  lock = YAML.safe_load(File.read(path), permitted_classes: [Date, Time], aliases: false) || {}
  next unless lock["status"] == "archived"

  add_identity.call("archiveLock", lock["change_id"], lock["revision"], Digest::SHA256.file(path).hexdigest)
end
(
  Dir.glob(ROOT.join("openspec/verification/hardware-evidence/*.json")) +
  Dir.glob(ROOT.join("openspec/platforms/conformance-evidence/*.json"))
).sort.each do |path|
  record = JSON.parse(File.read(path))
  next if record["evidenceId"].to_s.empty? || record["approvalId"].to_s.empty?

  add_identity.call("evidenceRecord", record["evidenceId"], record["schemaVersion"] || "1", Digest::SHA256.file(path).hexdigest)
end
Dir.glob(ROOT.join("openspec/platforms/conformance-evidence/bindings/*.json")).sort.each do |path|
  record = JSON.parse(File.read(path))
  next if record["bindingId"].to_s.empty? || record["approvalId"].to_s.empty?

  add_identity.call("evidenceRecord", record["bindingId"], record["schemaVersion"] || "1", Digest::SHA256.file(path).hexdigest)
end
Dir.glob(ROOT.join("openspec/platforms/release-subjects/*.json")).sort.each do |path|
  record = JSON.parse(File.read(path))
  next if record["releaseId"].to_s.empty? || record["approvalId"].to_s.empty?

  add_identity.call("releaseSubject", record["releaseId"], record["schemaVersion"] || "1", Digest::SHA256.file(path).hexdigest)
end
Dir.glob(ROOT.join("openspec/baselines/CORE-*.lock.yaml")).sort.each do |path|
  lock = YAML.safe_load(File.read(path), permitted_classes: [Date, Time], aliases: false) || {}
  next unless lock["status"] == "accepted"

  add_identity.call("acceptedBaseline", lock["baseline"], lock["revision"], Digest::SHA256.file(path).hexdigest)
end

if trust_policy["status"] == "accepted" && trust_policy["execution_gate"] == "open"
  ledger_location = ENV["ARKDECK_IDENTITY_LEDGER_SNAPSHOT"].to_s
  ledger_path = Pathname.new(ledger_location)
  begin
    ledger_outside_repository = ledger_path.absolute? && ledger_path.relative_path_from(ROOT).to_s.start_with?("../")
  rescue ArgumentError
    ledger_outside_repository = false
  end
  if ledger_location.empty? || !ledger_outside_repository || !ledger_path.file?
    errors << "open execution gate requires an external protected identity ledger snapshot"
  else
    begin
      ledger = JSON.parse(ledger_path.read)
      ledger_schema = versioned_schemas["https://arkdeck.dev/schemas/identity-ledger-snapshot-#{ledger['schemaVersion']}.json"]
      ledger_missing = ledger_schema ? ledger_schema.fetch("required") - ledger.keys : ["versioned schema"]
      ledger_extra = ledger_schema ? ledger.keys - ledger_schema.fetch("properties").keys : ledger.keys
      entries = Array(ledger["entries"])
      entry_keys = entries.map { |entry| [entry["kind"].to_s, entry["id"].to_s, entry["revision"].to_s] }
      entries_sorted = entries.sort_by { |entry| [entry["kind"].to_s, entry["id"].to_s, entry["revision"].to_s] }
      current_entries = current_identity_inventory.map do |(kind, id, revision), sha256|
        { "kind" => kind, "id" => id, "revision" => revision, "sha256" => sha256 }
      end.sort_by { |entry| [entry["kind"], entry["id"], entry["revision"]] }
      chain_shape_valid = ledger["revision"].is_a?(Integer) && ledger["revision"].positive? &&
                          (ledger["revision"] == 1 ? ledger["previousSnapshotSha256"].nil? : ledger["previousSnapshotSha256"].to_s.match?(/\A[a-f0-9]{64}\z/))
      generated_at_valid = ledger["generatedAt"].to_s.match?(RFC3339_DATE_TIME)
      exact_inventory = entries == entries_sorted && entry_keys.uniq.length == entry_keys.length && entries == current_entries
      valid_ledger = ledger_missing.empty? && ledger_extra.empty? && chain_shape_valid && generated_at_valid && exact_inventory &&
                     ledger["subjectType"] == "identityLedger" && ledger["decision"] == "approved" &&
                     external_trust_root && ledger["repositoryId"] == external_trust_root["repository_id"] &&
                     ledger["repositoryRevision"] == git_head_revision &&
                     externally_verified?(ledger_path, ledger_path, ledger, trusted_verifiers)
      errors << "protected identity ledger is stale, incomplete, ambiguous or externally unverified" unless valid_ledger
    rescue JSON::ParserError
      errors << "external protected identity ledger snapshot is invalid JSON"
    end
  end
end

if trust_policy["status"] == "accepted"
  trust_approval = approvals[trust_policy.dig("ratification", "approval_ref")]
  valid = external_trust_root_valid && trust_approval && trust_approval["subjectType"] == "trustPolicy" &&
          trust_approval["subjectId"] == trust_policy["policy"] &&
          trust_approval["subjectRevision"] == trust_policy["revision"] &&
          trust_approval["subjectSha256"] == Digest::SHA256.file(trust_policy_path).hexdigest &&
          trust_approval["decision"] == "approved" &&
          git_commit?(trust_approval["baseRevision"]) &&
          externally_verified?(approval_paths[trust_approval["approvalId"]], trust_policy_path, trust_approval, trusted_verifiers)
  errors << "accepted trust policy lacks externally verified approval" unless valid
end

if baseline && baseline["status"] == "accepted"
  baseline_approval = approvals[baseline.dig("ratification", "approval_ref")]
  valid = baseline_approval && baseline_approval["subjectType"] == "baseline" &&
          baseline_approval["subjectId"] == baseline["baseline"] &&
          baseline_approval["subjectRevision"] == baseline["revision"] &&
          baseline_approval["subjectSha256"] == Digest::SHA256.file(baseline_path).hexdigest &&
          baseline_approval["decision"] == "approved" &&
          git_commit?(baseline_approval["baseRevision"]) &&
          externally_verified?(approval_paths[baseline_approval["approvalId"]], baseline_path, baseline_approval, trusted_verifiers)
  errors << "accepted Core baseline lacks externally verified approval" unless valid
end

if integration_lock && integration_lock["status"] == "accepted"
  integration_approval = approvals[integration_lock.dig("ratification", "approval_ref")]
  valid = integration_approval && integration_approval["subjectType"] == "integrationLock" &&
          integration_approval["subjectId"] == integration_lock["lock"] &&
          integration_approval["subjectRevision"] == integration_lock["revision"] &&
          integration_approval["subjectSha256"] == Digest::SHA256.file(integration_lock_path).hexdigest &&
          integration_approval["decision"] == "approved" &&
          git_commit?(integration_approval["baseRevision"]) &&
          externally_verified?(approval_paths[integration_approval["approvalId"]], integration_lock_path, integration_approval, trusted_verifiers)
  errors << "accepted Integration lock lacks externally verified approval" unless valid
end

if platform_lock
  Array(platform_lock["profiles"]).select { |entry| %w[verified needsReverification].include?(entry["conformance_status"]) }.each do |entry|
    last = entry["last_verified"] || {}
    evidence_relative = last["evidence_path"].to_s
    evidence_path = ROOT.join(evidence_relative).expand_path
    contained = evidence_relative.match?(/\Aopenspec\/platforms\/conformance-evidence\/PCE-[A-Z0-9._-]+\.json\z/) &&
                evidence_path.to_s.start_with?("#{ROOT}#{File::SEPARATOR}")
    record = contained && evidence_path.file? ? JSON.parse(evidence_path.read) : {}
    release_subject_relative = last["release_subject_path"].to_s
    release_subject_path = ROOT.join(release_subject_relative).expand_path
    release_subject_contained = release_subject_relative.match?(/\Aopenspec\/platforms\/release-subjects\/PRS-[A-Z0-9._-]+\.json\z/) &&
                                release_subject_path.to_s.start_with?("#{ROOT}#{File::SEPARATOR}")
    release_subject = release_subject_contained && release_subject_path.file? ? JSON.parse(release_subject_path.read) : {}
    release_subject_approval = approvals[release_subject["approvalId"]]
    acceptance_results = Array(record["acceptanceResults"])
    acceptance_result_ids = acceptance_results.map { |result| result["acceptanceId"] }
    port_results = Array(record["portResults"])
    port_result_ids = port_results.map { |result| result["portId"] }
    platform_case_results = Array(record["platformCaseResults"])
    platform_case_result_ids = platform_case_results.map { |result| result["caseId"] }
    support_matrix = Array(record["supportMatrix"])
    support_cell_ids = support_matrix.map { |cell| cell["cellId"] }
    support_revisions = support_matrix.map { |cell| cell.dig("implementation", "resultRevision") }.uniq
    evidence_manifest = Array(record["evidenceManifest"])
    evidence_manifest_ids = evidence_manifest.map { |item| item["evidenceId"] }
    evidence_manifest_hashes = evidence_manifest.map { |item| item["sha256"] }
    conformance_result_cells = (acceptance_results + port_results + platform_case_results).flat_map { |result| Array(result["cells"]) }
    result_evidence_hashes = (conformance_result_cells.map { |cell| cell["evidenceSha256"] } + support_matrix.map { |cell| cell["evidenceSha256"] }).uniq.sort
    expected_bindings_by_evidence_hash = Hash.new { |hash, key| hash[key] = [] }
    support_by_id_for_bindings = support_matrix.to_h { |cell| [cell["cellId"], cell] }
    append_result_binding = lambda do |evidence_sha256, case_binding, cell_id|
      expected_bindings_by_evidence_hash[evidence_sha256] << case_binding
      support_cell = support_by_id_for_bindings[cell_id]
      if support_cell
        expected_bindings_by_evidence_hash[evidence_sha256] << {
          "subjectType" => "supportCell",
          "subjectId" => cell_id,
          "definitionSha256" => support_cell_contract_sha256(support_cell)
        }
      end
    end
    acceptance_results.each do |result|
      binding = {
        "subjectType" => "coreAcceptance",
        "subjectId" => result["acceptanceId"],
        "definitionSha256" => result["definitionSha256"]
      }
      Array(result["cells"]).each { |cell| append_result_binding.call(cell["evidenceSha256"], binding, cell["cellId"]) }
    end
    port_results.each do |result|
      binding = {
        "subjectType" => "port",
        "subjectId" => result["portId"],
        "definitionSha256" => result["definitionSha256"]
      }
      Array(result["cells"]).each { |cell| append_result_binding.call(cell["evidenceSha256"], binding, cell["cellId"]) }
    end
    platform_case_results.each do |result|
      binding = {
        "subjectType" => "platformCase",
        "subjectId" => result["caseId"],
        "definitionSha256" => result["definitionSha256"]
      }
      Array(result["cells"]).each { |cell| append_result_binding.call(cell["evidenceSha256"], binding, cell["cellId"]) }
    end
    support_matrix.each do |cell|
      expected_bindings_by_evidence_hash[cell["evidenceSha256"]] << {
        "subjectType" => "supportCell",
        "subjectId" => cell["cellId"],
        "definitionSha256" => support_cell_contract_sha256(cell)
      }
    end
    normalize_bindings = lambda do |bindings|
      Array(bindings).uniq.sort_by { |binding| [binding["subjectType"].to_s, binding["subjectId"].to_s, binding["definitionSha256"].to_s] }
    end
    evidence_manifest_bindings_valid = evidence_manifest.all? do |item|
      evidence_approval = approvals[item["approvalId"]]
      binding_relative = item["bindingPath"].to_s
      binding_path = ROOT.join(binding_relative).expand_path
      binding_contained = binding_relative.match?(/\Aopenspec\/platforms\/conformance-evidence\/bindings\/PCEV-[A-Z0-9._-]+\.json\z/) &&
                          binding_path.to_s.start_with?("#{ROOT}#{File::SEPARATOR}")
      binding_record = binding_contained && binding_path.file? ? JSON.parse(binding_path.read) : {}
      begin
        evidence_approval_precedes_observation = evidence_approval &&
                                                 DateTime.iso8601(evidence_approval.fetch("approvedAt")) <= DateTime.iso8601(record.fetch("observedAt"))
      rescue KeyError, Date::Error
        evidence_approval_precedes_observation = false
      end
      exact_bindings = normalize_bindings.call(item["caseBindings"]) == normalize_bindings.call(expected_bindings_by_evidence_hash[item["sha256"]])
      binding_exact = binding_contained && binding_path.file? && File.basename(binding_path, ".json") == item["evidenceId"] &&
                      item["bindingSha256"] == Digest::SHA256.file(binding_path).hexdigest &&
                      binding_record["bindingId"] == item["evidenceId"] &&
                      binding_record["artifactSha256"] == item["sha256"] &&
                      binding_record["classification"] == item["classification"] &&
                      binding_record["location"] == item["location"] &&
                      binding_record["coreBaselineSha256"] == item["coreBaselineSha256"] &&
                      binding_record["conformanceSuiteSha256"] == item["conformanceSuiteSha256"] &&
                      binding_record["integrationLockSha256"] == item["integrationLockSha256"] &&
                      binding_record["platformProfileSha256"] == item["platformProfileSha256"] &&
                      binding_record["platformVerificationSha256"] == item["platformVerificationSha256"] &&
                      binding_record["platformCaseManifestSha256"] == item["platformCaseManifestSha256"] &&
                      Array(binding_record["implementationRevisions"]).sort == Array(item["implementationRevisions"]).sort &&
                      normalize_bindings.call(binding_record["caseBindings"]) == normalize_bindings.call(item["caseBindings"]) &&
                      binding_record["approvalId"] == item["approvalId"]
      item["coreBaselineSha256"] == record.dig("coreBaseline", "sha256") &&
        item["conformanceSuiteSha256"] == record.dig("conformanceSuite", "sha256") &&
        item["integrationLockSha256"] == record.dig("integrationLock", "sha256") &&
        item["platformProfileSha256"] == record.dig("platformProfile", "profileSha256") &&
        item["platformVerificationSha256"] == record.dig("platformProfile", "verificationSha256") &&
        item["platformCaseManifestSha256"] == record.dig("platformProfile", "caseManifestSha256") &&
        Array(item["implementationRevisions"]).sort == support_revisions.sort &&
        exact_bindings && binding_exact && evidence_approval && evidence_approval["subjectType"] == "evidence" &&
        evidence_approval["subjectId"] == item["evidenceId"] && evidence_approval["subjectRevision"] == 1 &&
        evidence_approval["subjectSha256"] == item["bindingSha256"] &&
        evidence_approval["baseRevision"] == support_revisions.first && evidence_approval["decision"] == "approved" &&
        evidence_approval_precedes_observation &&
        externally_verified?(approval_paths[evidence_approval["approvalId"]], binding_path, evidence_approval, trusted_verifiers)
    end
    structurally_complete_results = record["acceptanceCount"] == acceptance_results.length &&
                                    acceptance_result_ids.uniq.length == acceptance_result_ids.length &&
                                    port_result_ids.uniq.length == port_result_ids.length &&
                                    platform_case_result_ids.uniq.length == platform_case_result_ids.length &&
                                    support_cell_ids.uniq.length == support_cell_ids.length &&
                                    evidence_manifest_ids.uniq.length == evidence_manifest_ids.length &&
                                    evidence_manifest_hashes.uniq.length == evidence_manifest_hashes.length &&
                                    evidence_manifest_hashes.sort == result_evidence_hashes &&
                                    evidence_manifest_bindings_valid &&
                                    acceptance_results.all? do |result|
                                      cells = Array(result["cells"])
                                      result["result"] == "passed" && !cells.empty? &&
                                        cells.map { |cell| cell["cellId"] }.sort == support_cell_ids.sort &&
                                        cells.map { |cell| cell["cellId"] }.uniq.length == cells.length &&
                                        cells.all? { |cell| cell["evidenceSha256"].to_s.match?(/\A[a-f0-9]{64}\z/) }
                                    end &&
                                    port_results.all? do |result|
                                      cells = Array(result["cells"])
                                      result["result"] == "passed" && !cells.empty? &&
                                        cells.map { |cell| cell["cellId"] }.sort == support_cell_ids.sort &&
                                        cells.map { |cell| cell["cellId"] }.uniq.length == cells.length &&
                                        cells.all? { |cell| cell["evidenceSha256"].to_s.match?(/\A[a-f0-9]{64}\z/) }
                                    end &&
                                    platform_case_results.all? do |result|
                                      cells = Array(result["cells"])
                                      result["result"] == "passed" && !cells.empty? &&
                                        cells.map { |cell| cell["cellId"] }.sort == support_cell_ids.sort &&
                                        cells.map { |cell| cell["cellId"] }.uniq.length == cells.length &&
                                        cells.all? { |cell| cell["evidenceSha256"].to_s.match?(/\A[a-f0-9]{64}\z/) }
                                    end &&
                                    support_matrix.all? do |cell|
                                      cell["result"] == "passed" && cell.dig("environment", "osName") == entry["platform"] &&
                                        cell["evidenceSha256"].to_s.match?(/\A[a-f0-9]{64}\z/) &&
                                        cell.dig("implementation", "releaseArtifactSha256").to_s.match?(/\A[a-f0-9]{64}\z/) &&
                                        git_commit?(cell.dig("implementation", "resultRevision")) &&
                                        git_ancestor?(cell.dig("implementation", "resultRevision"), git_head_revision)
                                    end
    approval = approvals[last["approval_id"]]
    support_matrix_hash = Digest::SHA256.hexdigest(JSON.generate(support_matrix))
    begin
      observed_at = DateTime.iso8601(record.fetch("observedAt"))
      valid_until = DateTime.iso8601(record.fetch("validUntil"))
      approved_at = DateTime.iso8601(approval.fetch("approvedAt")) if approval
      valid_approval_time = approval && observed_at <= approved_at && approved_at <= valid_until
      current_evaluation_window = hardware_evaluation_time && approved_at <= hardware_evaluation_time && hardware_evaluation_time <= valid_until
      release_created_at = DateTime.iso8601(release_subject.fetch("createdAt"))
      release_approved_at = DateTime.iso8601(release_subject_approval.fetch("approvedAt")) if release_subject_approval
      valid_release_time = release_subject_approval && release_created_at <= release_approved_at && release_approved_at <= observed_at
    rescue KeyError, Date::Error, NoMethodError
      valid_approval_time = false
      current_evaluation_window = false
      valid_release_time = false
    end
    normalized_support_matrix = support_matrix.map do |cell|
      { "cellId" => cell["cellId"], "implementation" => cell["implementation"], "environment" => cell["environment"] }
    end
    release_subject_valid = release_subject_contained && release_subject_path.file? &&
                            Digest::SHA256.file(release_subject_path).hexdigest == last["release_subject_sha256"] &&
                            record.dig("releaseSubject", "id") == release_subject["releaseId"] &&
                            record.dig("releaseSubject", "sha256") == last["release_subject_sha256"] &&
                            release_subject["platform"] == entry["platform"] && release_subject["supportMatrix"] == normalized_support_matrix &&
                            release_subject.dig("platformProfile", "id") == entry["id"] &&
                            release_subject.dig("platformProfile", "version") == entry["version"] &&
                            release_subject.dig("platformProfile", "profileSha256") == last["profile_sha256"] &&
                            release_subject.dig("platformProfile", "verificationSha256") == last["verification_sha256"] &&
                            release_subject.dig("platformProfile", "caseManifestSha256") == last["case_manifest_sha256"] &&
                            release_subject.dig("coreBaseline", "id") == last["core_baseline"] &&
                            release_subject.dig("coreBaseline", "sha256") == last["core_baseline_sha256"] &&
                            release_subject["conformanceSuiteSha256"] == last["conformance_suite_sha256"] &&
                            release_subject["integrationLockSha256"] == last["integration_lock_sha256"] &&
                            release_subject["approvalId"] == last["release_subject_approval_id"] &&
                            support_revisions.length == 1 && release_subject_approval && valid_release_time &&
                            release_subject_approval["subjectType"] == "platformReleaseSubject" &&
                            release_subject_approval["subjectId"] == release_subject["releaseId"] &&
                            release_subject_approval["subjectRevision"] == 1 &&
                            release_subject_approval["subjectSha256"] == last["release_subject_sha256"] &&
                            release_subject_approval["baseRevision"] == support_revisions.first &&
                            release_subject_approval["decision"] == "approved" &&
                            externally_verified?(approval_paths[release_subject_approval["approvalId"]], release_subject_path, release_subject_approval, trusted_verifiers)
    valid = contained && evidence_path.file? && File.basename(evidence_path, ".json") == record["evidenceId"] &&
            Digest::SHA256.file(evidence_path).hexdigest == last["evidence_sha256"] &&
            structurally_complete_results && release_subject_valid &&
            record["status"] == "verified" && record["platform"] == entry["platform"] &&
            record.dig("platformProfile", "id") == entry["id"] && record.dig("platformProfile", "version") == entry["version"] &&
            record.dig("platformProfile", "profileSha256") == last["profile_sha256"] &&
            record.dig("platformProfile", "verificationSha256") == last["verification_sha256"] &&
            record.dig("platformProfile", "caseManifestSha256") == last["case_manifest_sha256"] &&
            record.dig("coreBaseline", "id") == last["core_baseline"] && record.dig("coreBaseline", "sha256") == last["core_baseline_sha256"] &&
            record.dig("conformanceSuite", "sha256") == last["conformance_suite_sha256"] &&
            record.dig("integrationLock", "sha256") == last["integration_lock_sha256"] &&
            support_matrix_hash == last["support_matrix_sha256"] && record["validUntil"] == last["valid_until"] &&
            support_revisions.length == 1 &&
            Array(record["revalidationTriggers"]).sort == PLATFORM_REVALIDATION_TRIGGERS.sort && valid_approval_time &&
            record["approvalId"] == last["approval_id"] && approval && approval["subjectType"] == "platformConformance" &&
            approval["subjectId"] == record["evidenceId"] && approval["subjectRevision"] == 1 &&
            approval["subjectSha256"] == last["evidence_sha256"] && approval["baseRevision"] == support_revisions.first && approval["decision"] == "approved" &&
            externally_verified?(approval_paths[approval["approvalId"]], evidence_path, approval, trusted_verifiers)
    if entry["conformance_status"] == "verified"
      results_by_acceptance = acceptance_results.to_h { |result| [result["acceptanceId"], result] }
      support_by_id = support_matrix.to_h { |cell| [cell["cellId"], cell] }
      exact_acceptance_results = acceptance_result_ids.sort == acceptance.keys.sort &&
                                 acceptance_results.all? do |result|
                                   definition = core_case_definitions[result["acceptanceId"]] || {}
                                   minimum = definition["minimum_evidence"]
                                   cells = Array(result["cells"])
                                   cells_valid = cells.map { |cell| cell["cellId"] } == support_cell_ids && cells.all? do |cell|
                                     evidence_item = evidence_manifest.find { |item| item["sha256"] == cell["evidenceSha256"] }
                                     refs_valid = case minimum
                                                  when "parserGolden"
                                                    !Array(cell["fixtureRefs"]).empty? &&
                                                      (Array(cell["fixtureRefs"]) - conformance_fixture_ids).empty? &&
                                                      Array(cell["hardwareMatrixRefs"]).empty?
                                                  when "realHardware"
                                                    hardware_refs = Array(cell["hardwareMatrixRefs"])
                                                    !hardware_refs.empty? && Array(cell["fixtureRefs"]).empty? && hardware_refs.all? do |evidence_id|
                                                      hardware = verified_hardware[evidence_id]
                                                      hardware && hardware["platform"] == entry["platform"] &&
                                                        hardware["hostSupportCellId"] == cell["cellId"] &&
                                                        hardware["implementationRevision"] == support_by_id.dig(cell["cellId"], "implementation", "resultRevision") &&
                                                        Array(hardware["acceptanceIds"]).include?(result["acceptanceId"]) &&
                                                        hardware["platformCaseManifestSha256"] == entry["case_manifest_sha256"] &&
                                                        Array(hardware["acceptanceCaseBindings"]).any? do |binding|
                                                          binding["acceptanceId"] == result["acceptanceId"] &&
                                                            binding["testId"] == definition["test_id"] &&
                                                            binding["method"] == definition["method"] &&
                                                            binding["definitionSha256"] == acceptance_case_contract_sha256(result["acceptanceId"], definition)
                                                        end &&
                                                        hardware.dig("artifact", "sha256") == cell["evidenceSha256"]
                                                    end
                                                  else
                                                    Array(cell["fixtureRefs"]).empty? && Array(cell["hardwareMatrixRefs"]).empty?
                                                  end
                                     evidence_item && evidence_item["classification"] == minimum && refs_valid
                                   end
                                   definition["test_id"] == result["testId"] && definition["method"] == result["method"] &&
                                     result["definitionSha256"] == acceptance_case_contract_sha256(result["acceptanceId"], definition) &&
                                     minimum == result["minimumEvidence"] &&
                                     cells_valid
                                 end
      exact_port_results = port_result_ids.sort == ports.keys.sort && port_results.all? do |result|
        definition = port_contract_definitions[result["portId"]]
        definition && result["definitionSha256"] == port_contract_sha256(result["portId"], definition)
      end
      expected_platform_cases = Array(platform_case_definitions[entry["platform"]])
      expected_platform_case_ids = expected_platform_cases.map { |item| item["id"] }
      exact_platform_case_results = platform_case_result_ids.sort == expected_platform_case_ids.sort &&
                                    platform_case_results.all? do |result|
                                      expected_case = expected_platform_cases.find { |item| item["id"] == result["caseId"] }.to_h
                                      cells = Array(result["cells"])
                                      evidence_refs_valid = cells.map { |cell| cell["cellId"] } == support_cell_ids && cells.all? do |cell|
                                        evidence_item = evidence_manifest.find { |item| item["sha256"] == cell["evidenceSha256"] }
                                        hardware_refs = Array(cell["hardwareMatrixRefs"])
                                        cell_refs_valid = if expected_case["minimum_evidence"] == "realHardware"
                                                            !hardware_refs.empty? && hardware_refs.all? do |evidence_id|
                                                              hardware = verified_hardware[evidence_id]
                                                              hardware && hardware["platform"] == entry["platform"] &&
                                                                hardware["hostSupportCellId"] == cell["cellId"] &&
                                                                hardware["implementationRevision"] == support_by_id.dig(cell["cellId"], "implementation", "resultRevision") &&
                                                                Array(hardware["acceptanceIds"]).include?(result["caseId"]) &&
                                                                hardware["platformCaseManifestSha256"] == entry["case_manifest_sha256"] &&
                                                                Array(hardware["acceptanceCaseBindings"]).any? do |binding|
                                                                  binding["acceptanceId"] == result["caseId"] &&
                                                                    binding["testId"] == expected_case["test_id"] &&
                                                                    binding["method"] == expected_case["method"] &&
                                                                    binding["definitionSha256"] == acceptance_case_contract_sha256(result["caseId"], expected_case)
                                                                end &&
                                                                hardware.dig("artifact", "sha256") == cell["evidenceSha256"]
                                                            end
                                                          else
                                                            hardware_refs.empty?
                                                          end
                                        Array(cell["fixtureRefs"]).empty? && cell_refs_valid && evidence_item &&
                                          evidence_item["classification"] == expected_case["minimum_evidence"]
                                      end
                                      expected_case["test_id"] == result["testId"] && expected_case["method"] == result["method"] &&
                                        result["definitionSha256"] == acceptance_case_contract_sha256(result["caseId"], expected_case) &&
                                        expected_case["minimum_evidence"] == result["minimumEvidence"] && evidence_refs_valid
                                    end
      expected_support_cells = Array(platform_support_definitions[entry["platform"]])
      exact_support_matrix = support_cell_ids == expected_support_cells.map { |cell| cell["id"] } &&
                             support_matrix.each_with_index.all? do |cell, index|
                               expected_cell = expected_support_cells[index] || {}
                               environment = cell["environment"] || {}
                               evidence_item = evidence_manifest.find { |item| item["sha256"] == cell["evidenceSha256"] }
                               environment["architecture"] == expected_cell["architecture"] &&
                                 environment["packageFormat"] == expected_cell["package_format"] &&
                                 environment["osVersion"].to_s.start_with?(expected_cell["os_version_family"].to_s) &&
                                 evidence_item && evidence_item["classification"] == "platform"
                             end
      exact_port_evidence = port_results.all? do |result|
        cells = Array(result["cells"])
        cells.map { |cell| cell["cellId"] } == support_cell_ids && cells.all? do |cell|
          evidence_item = evidence_manifest.find { |item| item["sha256"] == cell["evidenceSha256"] }
          Array(cell["fixtureRefs"]).empty? && Array(cell["hardwareMatrixRefs"]).empty? &&
            evidence_item && evidence_item["classification"] == "platform"
        end
      end
      errors << "platform #{entry['platform']} conformance evidence does not exactly cover current Core AC/Test IDs" unless exact_acceptance_results
      errors << "platform #{entry['platform']} conformance evidence does not exactly cover current Core Port IDs" unless exact_port_results
      errors << "platform #{entry['platform']} conformance evidence does not exactly cover current platform release cases" unless exact_platform_case_results
      errors << "platform #{entry['platform']} conformance evidence does not exactly cover its declared support matrix" unless exact_support_matrix
      errors << "platform #{entry['platform']} Port evidence is not classified as platform evidence" unless exact_port_evidence
      valid &&= record.dig("conformanceSuite", "id") == conformance["suite"] &&
                record.dig("conformanceSuite", "sha256") == Digest::SHA256.file(conformance_path).hexdigest &&
                record.dig("integrationLock", "id") == integration_lock["lock"] &&
                record["acceptanceCount"] == conformance.dig("acceptance_index", "count") &&
                results_by_acceptance.length == conformance.dig("acceptance_index", "count") &&
                record.dig("platformProfile", "caseManifestSha256") == entry["case_manifest_sha256"] &&
                current_evaluation_window && exact_acceptance_results && exact_port_results && exact_port_evidence && exact_platform_case_results && exact_support_matrix
    end
    errors << "platform #{entry['platform']} #{entry['conformance_status']} lacks matching externally verified four-axis evidence" unless valid
  end
end

platform_history_records.each do |record|
  historical_lock = record["document"]
  historical_path = record["path"]
  historical_approval = approvals[historical_lock.dig("ratification", "approval_ref")]
  valid = historical_approval && historical_approval["subjectType"] == "platformLock" &&
          historical_approval["subjectId"] == historical_lock["lock"] &&
          historical_approval["subjectRevision"] == historical_lock["revision"] &&
          historical_approval["subjectSha256"] == Digest::SHA256.file(historical_path).hexdigest &&
          historical_approval["decision"] == "approved" &&
          git_commit?(historical_approval["baseRevision"]) &&
          externally_verified?(approval_paths[historical_approval["approvalId"]], historical_path, historical_approval, trusted_verifiers)
  errors << "historical platform lock #{relative(historical_path)} lacks externally verified immutable approval" unless valid
end


if platform_lock && platform_lock["status"] == "accepted"
  platform_approval = approvals[platform_lock.dig("ratification", "approval_ref")]
  begin
    platform_approved_at = DateTime.iso8601(platform_approval.fetch("approvedAt")) if platform_approval
    platform_prerequisite_approvals = Array(platform_lock["profiles"]).select { |entry| entry["conformance_status"] == "verified" }.flat_map do |entry|
      [approvals[entry.dig("last_verified", "approval_id")], approvals[entry.dig("last_verified", "release_subject_approval_id")]]
    end
    platform_chronology_valid = platform_approval && platform_prerequisite_approvals.all? do |prerequisite|
      prerequisite && DateTime.iso8601(prerequisite.fetch("approvedAt")) <= platform_approved_at
    end
  rescue KeyError, Date::Error
    platform_chronology_valid = false
  end
  valid = platform_approval && platform_approval["subjectType"] == "platformLock" &&
          platform_approval["subjectId"] == platform_lock["lock"] &&
          platform_approval["subjectRevision"] == platform_lock["revision"] &&
          platform_approval["subjectSha256"] == Digest::SHA256.file(platform_lock_path).hexdigest &&
          platform_approval["decision"] == "approved" &&
          git_commit?(platform_approval["baseRevision"]) &&
          platform_chronology_valid &&
          externally_verified?(approval_paths[platform_approval["approvalId"]], platform_lock_path, platform_approval, trusted_verifiers)
  errors << "accepted platform lock lacks externally verified approval" unless valid
end

if conformance && conformance["status"] == "accepted"
  conformance_approval = approvals[conformance.dig("ratification", "approval_ref")]
  valid = conformance_approval && conformance_approval["subjectType"] == "conformanceSuite" &&
          conformance_approval["subjectId"] == conformance["suite"] &&
          conformance_approval["subjectRevision"] == conformance["revision"] &&
          conformance_approval["subjectSha256"] == Digest::SHA256.file(conformance_path).hexdigest &&
          conformance_approval["decision"] == "approved" &&
          git_commit?(conformance_approval["baseRevision"]) &&
          conformance["core_baseline"] == baseline["baseline"] &&
          baseline["status"] == "accepted" &&
          integration_lock && integration_lock["status"] == "accepted" && integration_lock["execution_gate"] == "open" &&
          externally_verified?(approval_paths[conformance_approval["approvalId"]], conformance_path, conformance_approval, trusted_verifiers)
  errors << "accepted conformance suite lacks external approval or accepted Core binding" unless valid
end

if errors.empty?
  puts "SDD checks passed: #{requirements.length} requirements, #{acceptance.length} acceptance scenarios."
  exit 0
end

warn errors.map { |error| "ERROR: #{error}" }.join("\n")
exit 1
