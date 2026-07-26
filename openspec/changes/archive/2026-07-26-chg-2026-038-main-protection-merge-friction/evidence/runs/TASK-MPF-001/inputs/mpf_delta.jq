([($a[0] | paths(type != "object" and type != "array")),
  ($b[0] | paths(type != "object" and type != "array"))] | unique) as $ps
| [ $ps[] | . as $p
    | select(($a[0] | getpath($p)) != ($b[0] | getpath($p)))
    | {path: ($p | map(tostring) | join(".")),
       a: ($a[0] | getpath($p)),
       b: ($b[0] | getpath($p))} ]
