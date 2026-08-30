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

  /// Top-level tokens: product nodes plus the registry meta-commands.
  private static var rootTokens: [String] {
    CLICommandRegistry.nodes.map(\.token) + CLICommandRegistry.rootLeaves.map(\.token)
  }

  /// Subcommands per node, retired and refused ones included: a caller who
  /// types a retired token deserves to be completed to it and then told it is
  /// retired, rather than left guessing at a typo.
  private static var subcommands: [(node: String, tokens: [String])] {
    CLICommandRegistry.nodes.compactMap { node in
      let tokens = node.leaves.map(\.token).filter { !$0.isEmpty }
      return tokens.isEmpty ? nil : (node.token, tokens)
    }
  }

  private static func publishedOptions(node: String, leaf: String) -> [String] {
    guard let spec = CLICommandRegistry.node(node)?.leaves.first(where: { $0.token == leaf })
    else { return [] }
    return spec.options.filter(\.isPublished).map(\.name)
  }

  // MARK: bash

  private static func bash() -> String {
    var lines = [
      "# arkdeck bash completion — generated from \(CLICommandRegistry.schemaVersion)",
      "# Identities are never completed: see the CLI product spec §10.",
      "_arkdeck() {",
      "  local cur prev root",
      "  cur=\"${COMP_WORDS[COMP_CWORD]}\"",
      "  root=\"\(rootTokens.joined(separator: " "))\"",
      "  if [ \"$COMP_CWORD\" -eq 1 ]; then",
      "    COMPREPLY=( $(compgen -W \"$root --help --version\" -- \"$cur\") )",
      "    return 0",
      "  fi",
      "  case \"${COMP_WORDS[1]}\" in",
    ]
    for (node, tokens) in subcommands {
      lines.append("    \(node))")
      lines.append("      if [ \"$COMP_CWORD\" -eq 2 ]; then")
      lines.append(
        "        COMPREPLY=( $(compgen -W \"\(tokens.joined(separator: " "))\" -- \"$cur\") )")
      lines.append("        return 0")
      lines.append("      fi")
      lines.append("      case \"${COMP_WORDS[2]}\" in")
      for token in tokens {
        let options = publishedOptions(node: node, leaf: token)
        lines.append("        \(token))")
        lines.append(
          "          COMPREPLY=( $(compgen -W \"\(options.joined(separator: " ")) --help\" "
            + "-- \"$cur\") )")
        lines.append("          return 0 ;;")
      }
      lines.append("      esac ;;")
    }
    lines.append("    completion)")
    lines.append(
      "      COMPREPLY=( $(compgen -W \"bash zsh fish powershell\" -- \"$cur\") )")
    lines.append("      return 0 ;;")
    lines.append("    help)")
    lines.append("      COMPREPLY=( $(compgen -W \"$root\" -- \"$cur\") )")
    lines.append("      return 0 ;;")
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
      "  local -a roots",
      "  roots=(\(rootTokens.map { "'\($0)'" }.joined(separator: " ")))",
      "  if (( CURRENT == 2 )); then",
      "    _describe 'command' roots",
      "    return",
      "  fi",
      "  case \"${words[2]}\" in",
    ]
    for (node, tokens) in subcommands {
      lines.append("    \(node))")
      lines.append("      if (( CURRENT == 3 )); then")
      lines.append("        local -a subs")
      lines.append("        subs=(\(tokens.map { "'\($0)'" }.joined(separator: " ")))")
      lines.append("        _describe 'subcommand' subs")
      lines.append("        return")
      lines.append("      fi")
      lines.append("      case \"${words[3]}\" in")
      for token in tokens {
        let options = publishedOptions(node: node, leaf: token)
        lines.append("        \(token))")
        lines.append("          local -a opts")
        lines.append(
          "          opts=(\((options + ["--help"]).map { "'\($0)'" }.joined(separator: " ")))")
        lines.append("          _describe 'option' opts")
        lines.append("          return ;;")
      }
      lines.append("      esac ;;")
    }
    lines.append("    completion)")
    lines.append("      local -a shells")
    lines.append("      shells=('bash' 'zsh' 'fish' 'powershell')")
    lines.append("      _describe 'shell' shells")
    lines.append("      return ;;")
    lines.append("    help)")
    lines.append("      _describe 'command' roots")
    lines.append("      return ;;")
    lines.append("  esac")
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
    ]
    for node in CLICommandRegistry.nodes {
      lines.append(
        "complete -c arkdeck -n '__fish_use_subcommand' -a '\(node.token)' "
          + "-d '\(escapeFish(node.summary))'")
      for leaf in node.leaves where !leaf.token.isEmpty {
        lines.append(
          "complete -c arkdeck -n '__fish_seen_subcommand_from \(node.token)' "
            + "-a '\(leaf.token)' -d '\(escapeFish(leaf.summary))'")
        for option in leaf.options where option.isPublished {
          lines.append(
            "complete -c arkdeck -n '__fish_seen_subcommand_from \(leaf.token)' "
              + "-l '\(option.name.dropFirst(2))' -d '\(escapeFish(option.summary))'")
        }
      }
    }
    for leaf in CLICommandRegistry.rootLeaves {
      lines.append(
        "complete -c arkdeck -n '__fish_use_subcommand' -a '\(leaf.token)' "
          + "-d '\(escapeFish(leaf.summary))'")
    }
    lines.append(
      "complete -c arkdeck -n '__fish_seen_subcommand_from completion' "
        + "-a 'bash zsh fish powershell'")
    return lines.joined(separator: "\n") + "\n"
  }

  private static func escapeFish(_ text: String) -> String {
    text.replacingOccurrences(of: "'", with: "")
  }

  // MARK: powershell

  private static func powershell() -> String {
    var lines = [
      "# arkdeck PowerShell completion — generated from \(CLICommandRegistry.schemaVersion)",
      "# Identities are never completed: see the CLI product spec §10.",
      "Register-ArgumentCompleter -Native -CommandName arkdeck -ScriptBlock {",
      "  param($wordToComplete, $commandAst, $cursorPosition)",
      "  $tokens = $commandAst.CommandElements | ForEach-Object { $_.ToString() }",
      "  $roots = @(\(rootTokens.map { "'\($0)'" }.joined(separator: ", ")))",
      "  if ($tokens.Count -le 2) {",
      "    return $roots | Where-Object { $_ -like \"$wordToComplete*\" } |",
      "      ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }",
      "  }",
      "  $subcommands = @{",
    ]
    for (node, tokens) in subcommands {
      lines.append("    '\(node)' = @(\(tokens.map { "'\($0)'" }.joined(separator: ", ")))")
    }
    lines.append("  }")
    lines.append("  $options = @{")
    for (node, tokens) in subcommands {
      for token in tokens {
        let options = publishedOptions(node: node, leaf: token) + ["--help"]
        lines.append(
          "    '\(node) \(token)' = @(\(options.map { "'\($0)'" }.joined(separator: ", ")))")
      }
    }
    lines.append("  }")
    lines.append("  $node = $tokens[1]")
    lines.append("  if ($tokens.Count -eq 3) {")
    lines.append("    $candidates = $subcommands[$node]")
    lines.append("  } else {")
    lines.append("    $candidates = $options[\"$node $($tokens[2])\"]")
    lines.append("  }")
    lines.append("  if ($null -eq $candidates) { return }")
    lines.append("  $candidates | Where-Object { $_ -like \"$wordToComplete*\" } |")
    lines.append("    ForEach-Object { [System.Management.Automation.CompletionResult]::new($_) }")
    lines.append("}")
    return lines.joined(separator: "\n") + "\n"
  }
}
