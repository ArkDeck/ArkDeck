.data.repository.branchProtectionRules.nodes
| map(select(.pattern == "main"))
| first
| {pattern,
   allowsForcePushes,
   lockBranch,
   bypass: {totalCount: .bypassForcePushAllowances.totalCount,
            actors: [.bypassForcePushAllowances.nodes[].actor
                     | {type: .__typename, login: (.login // null)}]}}
