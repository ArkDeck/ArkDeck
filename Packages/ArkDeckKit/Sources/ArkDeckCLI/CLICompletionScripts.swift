import Foundation

/// Static completion scripts, generated from the registry.
///
/// §10 is explicit that these stay static: target, execution, job, artifact and
/// resume identities are not completed, because completing them writes a
/// caller's device and job history into a shell cache that nothing in ArkDeck
/// controls. What a script offers is exactly what the registry publishes —
/// command paths and published option names — so a completion can never leak a
/// value the CLI itself would have refused to print.
///
/// Success on stdout is script bytes and nothing else (§8.1), which is why the
/// `completion` leaf refuses `--output`.
enum CLICompletionScripts {

  static func script(for shell: String) -> String? {
    switch shell {
    case "bash": return bash()
    case "zsh": return zsh()
    case "fish": return fish()
    case "powershell": return powershell()
    default: return nil
    }
  }

  // MARK: The table every generator reads

  /// What may follow one command prefix.
  ///
  /// Derived from the registry rather than from a hand-written nesting
  /// assumption: the platform surface is three tokens deep in places, and a
  /// generator that assumed two would silently stop completing there.
  struct CompletionRow {
    /// The tokens already typed, e.g. `["runtime", "hdc"]`. Empty at the root.
    let prefix: [String]
    /// Tokens that may come next.
    let next: [String]

    var key: String { prefix.joined(separator: " ") }
  }

  static func table() -> [CompletionRow] {
    var rows: [CompletionRow] = [
      CompletionRow(
        prefix: [],
        next: CLICommandRegistry.nodes.map(\.token) + CLICommandRegistry.rootLeaves.map(\.token))
    ]
    func walk(_ node: CLINodeSpec, prefix: [String]) {
      let path = prefix + [node.token]
      // Retired and refused tokens are offered too: a caller who types one
      // deserves to be completed to it and then told it is retired, rather
      // than left wondering whether they mistyped.
      if !node.childTokens.isEmpty {
        rows.append(CompletionRow(prefix: path, next: node.childTokens))
      }
      for group in node.groups { walk(group, prefix: path) }
    }
    for node in CLICommandRegistry.nodes { walk(node, prefix: []) }

    // A leaf completes to its published options.
    for (path, leaf) in CLICommandRegistry.allLeaves() {
      let options = leaf.options.filter(\.isPublished).map(\.name)
      let positionals = leaf.positionals.compactMap { spec -> [String]? in
        if case .enumeration(let values) = spec.grammar { return values }
        return nil
      }.flatMap { $0 }
      let next = positionals + options + ["--help"]
      rows.append(CompletionRow(prefix: path, next: next))
    }
    return rows
  }

  // MARK: bash

  /// A `case` over the joined prefix rather than an associative array: macOS
  /// still ships bash 3.2, which has no `declare -A`.
  private static func bash() -> String {
    var lines = [
      "# arkdeck bash completion — generated from \(CLICommandRegistry.schemaVersion)",
      "# Identities are never completed: see the CLI product spec §10.",
      "_arkdeck() {",
      "  local cur prefix i",
      "  cur=\"${COMP_WORDS[COMP_CWORD]}\"",
      "  prefix=\"\"",
      "  for ((i=1; i<COMP_CWORD; i++)); do",
      "    case \"${COMP_WORDS[i]}\" in",
      "      -*) ;;",
      "      *) if [ -z \"$prefix\" ]; then prefix=\"${COMP_WORDS[i]}\";",
      "         else prefix=\"$prefix ${COMP_WORDS[i]}\"; fi ;;",
      "    esac",
      "  done",
      "  case \"$prefix\" in",
    ]
    for row in table() {
      lines.append("    \"\(row.key)\")")
      lines.append(
        "      COMPREPLY=( $(compgen -W \"\(row.next.joined(separator: " "))\" -- \"$cur\") ) ;;")
    }
    lines.append("    *) COMPREPLY=() ;;")
    lines.append("  esac")
    lines.append("  return 0")
    lines.append("}")
    lines.append("complete -F _arkdeck arkdeck")
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: zsh

  private static func zsh() -> String {
    var lines = [
      "#compdef arkdeck",
      "# generated from \(CLICommandRegistry.schemaVersion); identities are never completed.",
      "_arkdeck() {",
      "  local prefix word",
      "  prefix=\"\"",
      "  for word in \"${words[@]:1:$((CURRENT - 2))}\"; do",
      "    case \"$word\" in",
      "      -*) ;;",
      "      *) if [[ -z \"$prefix\" ]]; then prefix=\"$word\"; else prefix=\"$prefix $word\"; fi ;;",
      "    esac",
      "  done",
      "  local -a candidates",
      "  case \"$prefix\" in",
    ]
    for row in table() {
      lines.append("    \"\(row.key)\")")
      lines.append("      candidates=(\(row.next.map { "'\($0)'" }.joined(separator: " "))) ;;")
    }
    lines.append("    *) candidates=() ;;")
    lines.append("  esac")
    lines.append("  (( ${#candidates} )) && _describe 'arkdeck' candidates")
    lines.append("}")
    lines.append("_arkdeck \"$@\"")
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: fish

  private static func fish() -> String {
    var lines = [
      "# arkdeck fish completion — generated from \(CLICommandRegistry.schemaVersion)",
      "# Identities are never completed: see the CLI product spec §10.",
      "complete -c arkdeck -f",
      "function __arkdeck_prefix",
      "  set -l tokens (commandline -poc)",
      "  set -l parts",
      "  for token in $tokens[2..-1]",
      "    if not string match -q -- '-*' $token",
      "      set parts $parts $token",
      "    end",
      "  end",
      "  string join ' ' $parts",
      "end",
    ]
    for row in table() {
      let condition =
        row.prefix.isEmpty
        ? "test -z (__arkdeck_prefix)" : "test (__arkdeck_prefix) = '\(row.key)'"
      for token in row.next {
        lines.append("complete -c arkdeck -n \"\(condition)\" -a '\(token)'")
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: powershell

  private static func powershell() -> String {
    var lines = [
      "# arkdeck PowerShell completion — generated from \(CLICommandRegistry.schemaVersion)",
      "# Identities are never completed: see the CLI product spec §10.",
      "Register-ArgumentCompleter -Native -CommandName arkdeck -ScriptBlock {",
      "  param($wordToComplete, $commandAst, $cursorPosition)",
      "  $next = @{",
    ]
    for row in table() {
      lines.append("    '\(row.key)' = @(\(row.next.map { "'\($0)'" }.joined(separator: ", ")))")
    }
    lines.append("  }")
    lines.append(
      "  $tokens = @($commandAst.CommandElements | ForEach-Object { $_.ToString() })"
    )
    lines.append("  $parts = @()")
    lines.append("  if ($tokens.Count -gt 1) {")
    lines.append("    foreach ($token in $tokens[1..($tokens.Count - 1)]) {")
    lines.append("      if ($token -eq $wordToComplete) { continue }")
    lines.append("      if ($token -notlike '-*') { $parts += $token }")
    lines.append("    }")
    lines.append("  }")
    lines.append("  $candidates = $next[($parts -join ' ')]")
    lines.append("  if ($null -eq $candidates) { return }")
    lines.append("  $candidates | Where-Object { $_ -like \"$wordToComplete*\" } |")
    lines.append("    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }")
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
  }
}
