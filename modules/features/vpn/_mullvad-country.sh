# Read by modules/features/vpn/client.nix: for a dial, steps the country, toggles, prints the state.

# "<code> <name>" per country, in Mullvad's order; the location set now, if it is one
countries() { mullvad relay list | sed -n 's/^\([A-Z].*\) (\([a-z][a-z]\))$/\2 \1/p'; }
current() { mullvad relay get | awk '$1 == "Location:" { print $3; exit }'; }
status() { mullvad status | head -n 1; }

case "${1:-show}" in
  next | prev)
    mapfile -t list < <(countries)
    here=$(current)
    # with no country set (any), next starts at the first and prev at the last
    index=-1
    for i in "${!list[@]}"; do
      [ "${list[$i]%% *}" = "$here" ] && index=$i
    done
    step=${2:-1}
    [ "$1" = prev ] && step=$((-step))
    [ "$index" = -1 ] && [ "$1" = prev ] && index=0
    index=$(((index + step) % ${#list[@]} + ${#list[@]}))
    mullvad relay set location "${list[$((index % ${#list[@]}))]%% *}" >/dev/null
    ;;
  toggle)
    case $(status) in
      Connected* | Connecting*) mullvad disconnect >/dev/null ;;
      *) mullvad connect >/dev/null ;;
    esac
    ;;
  show)
    case $(status) in
      Connected*) level=on ;;
      Connecting*) level=warn ;;
      *) level=off ;;
    esac
    here=$(current)
    name=$(countries | awk -v c="$here" '$1 == c { $1 = ""; sub(/^ /, ""); print; exit }')
    echo "$level ${name:-any}"
    ;;
  *)
    echo "mullvad-country: unknown command '$1', expected next|prev [n], toggle or show" >&2
    exit 1
    ;;
esac
