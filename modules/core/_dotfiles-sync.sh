# Read by modules/core/home.nix: links the dotfile folders' files into $LINK_ROOT.

# drop links into either home whose file is gone; ownership is read off the link target
if [ -f "$LINK_LIST" ]; then
  while IFS= read -r link; do
    [ -L "$link" ] && [ ! -e "$link" ] || continue
    target=$(readlink -- "$link")
    for src in "${DOTFILES[@]}"; do
      case "$target" in "$src"/*) rm -f -- "$link" ;; esac
    done
  done <"$LINK_LIST"
fi
for src in "${DOTFILES[@]}"; do
  # a file at the top of ~ has no folder left to be found through below
  find "$LINK_ROOT" -maxdepth 1 -xtype l -lname "$src/*" -delete
  [ -d "$src" ] || continue
  while IFS= read -r top; do
    [ -e "$LINK_ROOT/$top" ] || continue
    find "$LINK_ROOT/$top" -xtype l -lname "$src/*" -delete
  done < <(find "$src" -mindepth 1 -maxdepth 1 -printf '%P\n')
done

# link every file from the first home that has it
mkdir -p -- "$(dirname -- "$LINK_LIST")"
: >"$LINK_LIST.new"
for i in "${!DOTFILES[@]}"; do
  src=${DOTFILES[i]}
  [ -d "$src" ] || continue
  while IFS= read -r rel; do
    for more in "${DOTFILES[@]:0:i}"; do
      [ -e "$more/$rel" ] && continue 2
    done
    link="$LINK_ROOT/$rel"
    printf '%s\n' "$link" >>"$LINK_LIST.new"

    # already pointing at the right file
    [ "$(readlink -- "$link" 2>/dev/null)" = "$src/$rel" ] && continue

    # never overwrite a real file; atomic-save editors replace links with files
    if [ -e "$link" ] && [ ! -L "$link" ]; then
      echo "dotfiles: $link is a real file, moving it to $link.bak" >&2
      mv -- "$link" "$link.bak"
    fi

    mkdir -p -- "$(dirname -- "$link")"
    ln -sfnT -- "$src/$rel" "$link"
  done < <(find "$src" -type f -printf '%P\n')
done
mv -- "$LINK_LIST.new" "$LINK_LIST"
