#!/usr/bin/env ruby
# frozen_string_literal: true

# Adversarial self-test for the SDD guard.
#
# The guard (check-sdd.rb) is the single enforcement point for the whole
# governance model, so "the guard passes" is only meaningful if the guard is
# also proven to FAIL on tampering. Each case below copies the repository to
# a scratch directory, injects exactly one class of violation and asserts
# that the guard reports the expected error. A mutation the guard fails to
# detect fails this suite.
#
# Run alongside scripts/check-sdd.sh; CI must require both to pass.
# Override the scratch location with ARKDECK_SELFTEST_TMPDIR if needed.

require "fileutils"
require "open3"
require "pathname"
require "tmpdir"

SOURCE_ROOT = Pathname.new(__dir__).parent.expand_path
COPY_EXCLUDES = %w[.git .claude __pycache__].freeze

def copy_repo(destination)
  SOURCE_ROOT.children.each do |entry|
    next if COPY_EXCLUDES.include?(entry.basename.to_s)
    FileUtils.cp_r(entry, destination, preserve: true)
  end
  Dir.glob(File.join(destination, "**", "__pycache__")).each { |dir| FileUtils.rm_rf(dir) }
end

def run_guard(root)
  Open3.capture3("ruby", File.join(root, "scripts", "check-sdd.rb"))
end

def run_relock(root)
  Open3.capture3("ruby", File.join(root, "scripts", "relock-baseline.rb"))
end

Case = Struct.new(:name, :expected_error, :mutation, keyword_init: true)

CASES = [
  Case.new(
    name: "tamper-protected-content",
    expected_error: %r{baseline protected hash mismatch: openspec/constitution\.md},
    mutation: ->(root) { File.write(File.join(root, "openspec/constitution.md"), "\n<!-- tampered -->\n", mode: "a") }
  ),
  Case.new(
    name: "inject-unregistered-protected-file",
    expected_error: %r{baseline omits protected files: .*zzz-injected},
    mutation: ->(root) { File.write(File.join(root, "openspec/contracts/zzz-injected.schema.json"), "{}\n") }
  ),
  Case.new(
    name: "delete-protected-file",
    expected_error: %r{baseline protected path missing: openspec/specs/flashing/spec\.md},
    mutation: ->(root) { FileUtils.rm(File.join(root, "openspec/specs/flashing/spec.md")) }
  ),
  Case.new(
    name: "tamper-file-manifest",
    expected_error: %r{baseline hash mismatch: openspec/baselines/},
    mutation: lambda do |root|
      manifest = Dir.glob(File.join(root, "openspec/baselines/*.files.yaml")).fetch(0)
      text = File.read(manifest)
      # Flip the first hex digit of the first recorded hash.
      File.write(manifest, text.sub(/sha256: ([0-9a-f])/) { "sha256: #{Regexp.last_match(1) == '0' ? '1' : '0'}" })
    end
  ),
  Case.new(
    name: "unsorted-file-manifest",
    expected_error: /baseline file manifest is not path-sorted/,
    mutation: lambda do |root|
      manifest = Dir.glob(File.join(root, "openspec/baselines/*.files.yaml")).fetch(0)
      lines = File.readlines(manifest)
      first = lines.index { |line| line.start_with?("- path: ") }
      # Swap the first two two-line entries so paths are out of order.
      lines[first, 4] = [lines[first + 2], lines[first + 3], lines[first], lines[first + 1]]
      File.write(manifest, lines.join)
    end
  ),
  Case.new(
    name: "drop-acceptance-index-entry",
    expected_error: /acceptance index missing: AC-/,
    mutation: lambda do |root|
      index = File.join(root, "openspec/verification/acceptance-index.txt")
      lines = File.readlines(index)
      victim = lines.index { |line| line.start_with?("AC-") }
      lines.delete_at(victim)
      File.write(index, lines.join)
    end
  ),
  Case.new(
    name: "add-unknown-acceptance-id",
    expected_error: /acceptance index has unknown IDs: AC-ZZZ-999-01/,
    mutation: lambda do |root|
      File.write(File.join(root, "openspec/verification/acceptance-index.txt"), "AC-ZZZ-999-01\n", mode: "a")
    end
  ),
  Case.new(
    name: "duplicate-acceptance-scenario",
    expected_error: /duplicate Acceptance AC-DUMP-001-01/,
    mutation: lambda do |root|
      spec = File.join(root, "openspec/specs/ui-dump/spec.md")
      File.write(spec, "\n#### Scenario: AC-DUMP-001-01 duplicate injection\n\n- GIVEN x\n- WHEN y\n- THEN z\n", mode: "a")
    end
  ),
  Case.new(
    name: "requirement-without-scenario",
    expected_error: /REQ-ZZZ-001 has no Scenario/,
    mutation: lambda do |root|
      spec = File.join(root, "openspec/specs/ui-dump/spec.md")
      File.write(spec, "\n### Requirement: REQ-ZZZ-001 Injected requirement\n\nTHE SYSTEM SHALL be detected.\n", mode: "a")
    end
  ),
  Case.new(
    name: "escalate-task-packet-status",
    expected_error: /ready Task TASK-M0A-001/,
    mutation: lambda do |root|
      packet = File.join(root, "openspec/changes/chg-2026-001-macos-m0a/task-packets/TASK-M0A-001.json")
      File.write(packet, File.read(packet).sub('"status": "draft"', '"status": "ready"'))
    end
  ),
  Case.new(
    name: "tamper-platform-profile",
    expected_error: %r{platform lock hash mismatch: openspec/platforms/linux/profile\.md},
    mutation: ->(root) { File.write(File.join(root, "openspec/platforms/linux/profile.md"), "\n<!-- tampered -->\n", mode: "a") }
  )
].freeze

failures = []
base_tmp = ENV["ARKDECK_SELFTEST_TMPDIR"]
FileUtils.mkdir_p(base_tmp) if base_tmp

Dir.mktmpdir("arkdeck-guard-selftest-", base_tmp) do |tmp|
  # Case 0: the pristine copy must be green, otherwise mutations prove nothing.
  pristine = File.join(tmp, "pristine")
  FileUtils.mkdir_p(pristine)
  copy_repo(pristine)
  stdout, stderr, status = run_guard(pristine)
  if status.success?
    puts "PASS pristine-copy-is-green"
  else
    failures << "pristine-copy-is-green"
    puts "FAIL pristine-copy-is-green — guard must pass on an unmodified tree before mutations mean anything:\n#{stderr}"
  end

  CASES.each do |test_case|
    root = File.join(tmp, test_case.name)
    FileUtils.mkdir_p(root)
    copy_repo(root)
    test_case.mutation.call(root)
    _stdout, stderr, status = run_guard(root)
    if status.success?
      failures << test_case.name
      puts "FAIL #{test_case.name} — guard did not detect the mutation"
    elsif stderr.match?(test_case.expected_error)
      puts "PASS #{test_case.name}"
    else
      failures << test_case.name
      puts "FAIL #{test_case.name} — guard failed, but without the expected error #{test_case.expected_error.inspect}:\n#{stderr}"
    end
  end

  # Round-trip: relock must repair candidate drift and return the guard to
  # green, and must refuse to run against an accepted baseline.
  round_trip = File.join(tmp, "relock-repairs-drift")
  FileUtils.mkdir_p(round_trip)
  copy_repo(round_trip)
  File.write(File.join(round_trip, "openspec/constitution.md"), "\n<!-- candidate drift -->\n", mode: "a")
  _stdout, _stderr, drift_status = run_guard(round_trip)
  relock_out, relock_err, relock_status = run_relock(round_trip)
  _stdout, post_err, post_status = run_guard(round_trip)
  if !drift_status.success? && relock_status.success? && post_status.success?
    puts "PASS relock-repairs-drift"
  else
    failures << "relock-repairs-drift"
    puts "FAIL relock-repairs-drift — drift detected: #{!drift_status.success?}, relock: #{relock_status.success?} (#{relock_err}#{relock_out}), post-relock guard: #{post_status.success?}\n#{post_err}"
  end

  refusal = File.join(tmp, "relock-refuses-accepted-baseline")
  FileUtils.mkdir_p(refusal)
  copy_repo(refusal)
  lock = Dir.glob(File.join(refusal, "openspec/baselines/*.lock.yaml")).fetch(0)
  File.write(lock, File.read(lock).sub(/^status: review$/, "status: accepted"))
  _stdout, refusal_err, refusal_status = run_relock(refusal)
  if !refusal_status.success? && refusal_err.include?("refusing to relock")
    puts "PASS relock-refuses-accepted-baseline"
  else
    failures << "relock-refuses-accepted-baseline"
    puts "FAIL relock-refuses-accepted-baseline — relock must never rewrite an accepted baseline"
  end
end

if failures.empty?
  puts "Guard self-test passed: #{CASES.length + 3} cases."
  exit 0
end

warn "Guard self-test FAILED: #{failures.join(', ')}"
exit 1
