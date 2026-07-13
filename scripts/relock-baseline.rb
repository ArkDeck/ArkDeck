#!/usr/bin/env ruby
# frozen_string_literal: true

# Candidate-baseline relock tool.
#
# Regenerates the Core baseline file manifest (<BASELINE>.files.yaml) from the
# shared protected-set definition and re-pins the manifest hash inside
# <BASELINE>.lock.yaml.
#
# This tool is ONLY valid while the baseline is an unratified candidate:
# the lock's change_rule states "A review candidate may be regenerated while
# the execution gate is closed. After acceptance, never rewrite this baseline
# or its file manifest in place." The tool enforces that rule and refuses to
# run against an accepted baseline or an open execution gate; after
# ratification a semantic change requires an approved Core change and a new
# CORE-x.y.z baseline instead.
#
# The tool never edits any protected file's content. It only recomputes
# hashes over the current protected set and reports what drifted, so a human
# reviewer can audit the exact delta before committing.

require "date"
require "digest"
require "pathname"
require "yaml"

require_relative "sdd-protected-set"

ROOT = Pathname.new(__dir__).parent.expand_path

config = YAML.safe_load(ROOT.join("openspec/config.yaml").read, aliases: true)
baseline_id = config.fetch("current_core_baseline")
lock_path = ROOT.join("openspec/baselines/#{baseline_id}.lock.yaml")
abort "ERROR: baseline lock not found: #{lock_path}" unless lock_path.file?

lock_text = lock_path.read
lock = YAML.safe_load(lock_text, permitted_classes: [Date, Time], aliases: true)

# --- candidate-only guard rails -------------------------------------------
ratification = lock.fetch("ratification", {})
violations = []
violations << "lock status is '#{lock['status']}' (must not be 'accepted')" if lock["status"] == "accepted"
violations << "lock has accepted_at set" unless lock["accepted_at"].nil?
violations << "ratification approval_ref is set" unless ratification["approval_ref"].nil?
violations << "execution gate is not closed" unless ratification["execution_gate"] == "closed"
unless violations.empty?
  abort "ERROR: refusing to relock a non-candidate baseline:\n  - #{violations.join("\n  - ")}\n" \
        "After acceptance, create an approved Core change and a new CORE-x.y.z baseline instead."
end

manifest_ref = lock.fetch("file_manifest")
manifest_path = ROOT.join(manifest_ref.fetch("path"))

# --- read previous manifest for the drift report ---------------------------
previous = {}
if manifest_path.file?
  previous_doc = YAML.safe_load(manifest_path.read, permitted_classes: [Date, Time], aliases: true) || {}
  Array(previous_doc["files"]).each { |entry| previous[entry["path"]] = entry["sha256"] }
end

# --- regenerate manifest ----------------------------------------------------
files = sdd_protected_files(ROOT)
current = files.to_h { |path| [path, Digest::SHA256.file(ROOT.join(path)).hexdigest] }

today = Date.today.iso8601
manifest_lines = [
  "---",
  "baseline: #{baseline_id}",
  "status: candidate",
  "generated_at: '#{today}'",
  "hash_algorithm: sha256",
  "file_count: #{files.length}",
  "files:"
]
files.each do |path|
  manifest_lines << "- path: #{path}"
  manifest_lines << "  sha256: #{current[path]}"
end
manifest_content = manifest_lines.join("\n") + "\n"
manifest_path.write(manifest_content)
manifest_hash = Digest::SHA256.hexdigest(manifest_content)

# --- re-pin manifest hash and generated_at inside the lock ------------------
manifest_rel = manifest_ref.fetch("path")
pin_pattern = /(path: #{Regexp.escape(manifest_rel)}\n\s*sha256: )[a-f0-9]{64}/
abort "ERROR: could not locate file_manifest pin inside #{lock_path}" unless lock_text.match?(pin_pattern)
updated_lock = lock_text.sub(pin_pattern) { "#{Regexp.last_match(1)}#{manifest_hash}" }
updated_lock = updated_lock.sub(/^generated_at: .*$/) { "generated_at: #{today}" }
lock_path.write(updated_lock)

# --- drift report -----------------------------------------------------------
added = files - previous.keys
removed = previous.keys - files
changed = (files & previous.keys).select { |path| previous[path] != current[path] }

puts "Relocked #{baseline_id}: #{files.length} protected files."
puts "  added   (#{added.length}): #{added.join(', ')}" unless added.empty?
puts "  removed (#{removed.length}): #{removed.join(', ')}" unless removed.empty?
puts "  changed (#{changed.length}): #{changed.join(', ')}" unless changed.empty?
puts "  manifest sha256: #{manifest_hash}"
puts "Review the drift above, run scripts/check-sdd.sh and scripts/guard-selftest.rb, then commit."
