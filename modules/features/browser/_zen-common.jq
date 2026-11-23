# Read by modules/features/browser/profile-files.nix: what every _zen-*.jq filter starts with.
# each filter reads the declared file as $d; upsert's f merges [row, declared row]
def upsert($decl; key; f):
  [.[] | key] as $have
  | map(. as $e | ([$decl[] | select(key == ($e | key))] | first) as $o
      | if $o != null then [$e, $o] | f else . end)
  + [$decl[] | select(key as $k | $have | index($k) | not)];
def only($decl; key): map(select(key as $k | [$decl[] | key] | index($k) != null));
$d[0] as $d |
