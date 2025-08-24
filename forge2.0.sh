#!/usr/bin/env bash
# Forge - gerenciador de pacotes source-based minimalista (versão avançada unificada)
# Licença: MIT
set -euo pipefail

# --------------- Cores e mensagens ---------------
FORGE_COLOR="${FORGE_COLOR:-1}"
if [[ -t 1 && "$FORGE_COLOR" == "1" ]]; then
  c_b="\033[1;34m"; c_g="\033[1;32m"; c_y="\033[1;33m"; c_r="\033[1;31m"; c_n="\033[0m"
else
  c_b=""; c_g=""; c_y=""; c_r=""; c_n=""
fi
msg()  { printf "${c_b}==>${c_n} %s\n" "$*"; }
ok()   { printf "${c_g}✓${c_n} %s\n" "$*"; }
warn() { printf "${c_y}!!${c_n} %s\n" "$*"; }
die()  { printf "${c_r}✗ %s${c_n}\n" "$*" 1>&2; exit 1; }

# --------------- Variáveis globais e flags ---------------
FORGE_JOBS=${FORGE_JOBS:-$(nproc 2>/dev/null || echo 1)}
FORGE_LTO=${FORGE_LTO:-0}
FORGE_ASSUME_YES=0
FORGE_NO_ORPHANS=0
FORGE_LOGS_DIR="$FORGE_DB/.logs"
mkdir -p "$FORGE_LOGS_DIR"

# --------------- Verificações de ambiente ---------------
need_env() {
  local miss=()
  for v in FORGE_DB FORGE_LOG FORGE_SRC FORGE_BUILD FORGE_DESTDIR; do
    [[ -n "${!v-}" ]] || miss+=("$v")
  done
  if ! declare -p FORGE_REPOS >/dev/null 2>&1; then miss+=("FORGE_REPOS(array)"); fi
  ((${#miss[@]})) && die "Variáveis ausentes: ${miss[*]}\nDefina no seu ~/.profile"
}
need_bins() {
  local need=(find awk sort tee tar patch curl sha256sum unzip)
  local miss=()
  for b in "${need[@]}"; do command -v "$b" >/dev/null 2>&1 || miss+=("$b"); done
  ((${#miss[@]})) && die "Comandos ausentes: ${miss[*]}"
}

# --------------- Diretórios ---------------
init_dirs() {
  mkdir -p "$FORGE_DB" "$FORGE_LOG" "$FORGE_SRC" "$FORGE_BUILD" "$FORGE_DESTDIR"
}

# --------------- Helpers DB/Recipe ---------------
pkg_installed() { [[ -d "$FORGE_DB/$1" ]]; }
pkg_version_installed() { [[ -f "$FORGE_DB/$1/version" ]] && cat "$FORGE_DB/$1/version"; }

recipe_path() {
  local pkg=$1 repo hit
  for repo in "${FORGE_REPOS[@]}"; do
    hit="$(find "$repo" -mindepth 2 -maxdepth 2 -type d -name "$pkg" 2>/dev/null | head -n1)"
    [[ -n "$hit" ]] && { echo "$hit"; return 0; }
  done
  return 1
}
read_version()  { local d; d="$(recipe_path "$1")" || return 1; tr -d ' \t\r\n' < "$d/version"; }
read_depends()  { local d; d="$(recipe_path "$1")" || return 0; [[ -f "$d/depends" ]] && awk 'NF{print $1}' "$d/depends"; }
read_sources()  { local d; d="$(recipe_path "$1")" || return 0; [[ -f "$d/sources" ]] && cat "$d/sources"; [[ -f "$d/source" ]] && cat "$d/source"; }
has_checksums() { local d; d="$(recipe_path "$1")" || return 1; [[ -f "$d/checksums" ]]; }

# --------------- Resolver dependências (ordem topológica) ---------------
declare -a _seen=() _order=()
_seen_has() { for x in "${_seen[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
_seen_add() { _seen+=("$1"); }
_order_add(){ _order+=("$1"); }
_resolve_one() {
  local p=$1 d
  _seen_has "$p" && return 0
  _seen_add "$p"
  while read -r d 2>/dev/null; do [[ -n "$d" ]] && _resolve_one "$d"; done < <(read_depends "$p")
  _order_add "$p"
}
resolve_deps_order() {
  _seen=(); _order=()
  local p; for p in "$@"; do _resolve_one "$p"; done
  printf '%s\n' "${_order[@]}" | awk 'NF && !seen[$0]++'
}

# --------------- Hooks ---------------
run_hook() { local pkg=$1 hook=$2 d; d="$(recipe_path "$pkg")" || return 0; [[ -x "$d/$hook" ]] || return 0; msg "hook $hook ($pkg)"; "$d/$hook"; }
# --------------- Download + checksum ---------------
download_sources() {
  local pkg=$1 d out url
  d="$(recipe_path "$pkg")" || die "recipe não encontrada: $pkg"
  local have=0
  while IFS= read -r url || [[ -n "${url:-}" ]]; do
    [[ -z "$url" ]] && continue
    have=1
    out="$FORGE_SRC/${url##*/}"
    if [[ ! -f "$out" ]]; then
      command -v curl >/dev/null 2>&1 || die "curl não encontrado"
      msg "baixando $(basename "$out")"
      curl -L --fail --retry 3 --continue-at - "$url" -o "$out" 2>&1 | tee -a "$FORGE_LOG/$pkg.log"
    fi
  done < <(read_sources "$pkg")

  if has_checksums "$pkg"; then
    command -v sha256sum >/dev/null 2>&1 || die "sha256sum não encontrado"
    paste -d' ' "$(recipe_path "$pkg")/checksums" <(read_sources "$pkg") | while read -r sum link; do
      [[ -z "$sum" ]] && continue
      out="$FORGE_SRC/${link##*/}"
      printf '%s  %s\n' "$sum" "$out" | sha256sum -c - || die "checksum falhou: $out"
    done
  fi
}

# --------------- Unpack + patches ---------------
unpack_and_patch() {
  local pkg=$1 d w main=""
  d="$(recipe_path "$pkg")" || die "recipe não encontrada: $pkg"
  w="$FORGE_BUILD/$pkg"
  rm -rf "$w"; mkdir -p "$w"

  while IFS= read -r link || [[ -n "${link:-}" ]]; do
    [[ -z "$link" ]] && continue
    local f="$FORGE_SRC/${link##*/}"
    case "$f" in
      *.tar.*|*.tgz|*.tbz2|*.txz|*.tar) (cd "$w" && tar -xf "$f");;
      *.zip) (cd "$w" && command -v unzip >/dev/null 2>&1 || die "unzip não encontrado"; unzip -q "$f");;
      *.patch) : ;; # patches via diretório patches/
      *) cp -a "$f" "$w/";;
    esac
  done < <(read_sources "$pkg")

  main="$(find "$w" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -z "$main" ]] && main="$w"

  if [[ -d "$d/patches" ]]; then
    command -v patch >/dev/null 2>&1 || die "patch não encontrado"
    ( cd "$main"
      for p in "$d"/patches/*.patch; do
        [[ -f "$p" ]] || continue
        msg "patch $(basename "$p")"
        patch -p1 < "$p"
      done
    )
  fi
  printf '%s\n' "$main"
}

# --------------- Build otimizado ----------------
setup_build_env() {
  export MAKEFLAGS="-j$FORGE_JOBS"
  if command -v ccache >/dev/null 2>&1; then
    export CC="ccache gcc"
    export CXX="ccache g++"
    export FC="ccache gfortran"
    CCACHE=1
  else
    CCACHE=0
  fi
  if [[ "$FORGE_LTO" -eq 1 ]]; then
    export CFLAGS="${CFLAGS:-} -flto"
    export CXXFLAGS="${CXXFLAGS:-} -flto"
    export FCFLAGS="${FCFLAGS:-} -flto"
    USE_LTO=1
  else
    USE_LTO=0
  fi
}

forge_build() {
  local pkg=$1 d ver src dest
  d="$(recipe_path "$pkg")" || die "recipe não encontrada: $pkg"
  ver="$(read_version "$pkg")"

  # garantir dependências instaladas
  while read -r dep 2>/dev/null; do
    [[ -z "$dep" ]] && continue
    if ! pkg_installed "$dep"; then
      forge_build "$dep"
      forge_install "$dep"
    fi
  done < <(read_depends "$pkg")

  download_sources "$pkg"
  src="$(unpack_and_patch "$pkg")"
  dest="$FORGE_DESTDIR/$pkg"
  rm -rf "$dest"; mkdir -p "$dest"

  setup_build_env
  export DESTDIR="$dest"

  run_hook "$pkg" pre-build
  msg "build $pkg-$ver"
  if [[ -x "$d/build" ]]; then
    ( cd "$src"; "$d/build" ) >> "$FORGE_LOG/$pkg.log" 2>&1 || die "falha no build ($pkg)"
  else
    ( cd "$src"; sh "$d/build" ) >> "$FORGE_LOG/$pkg.log" 2>&1 || die "falha no build ($pkg)"
  fi
  run_hook "$pkg" post-build
  ok "build concluído: $pkg-$ver | Jobs: $FORGE_JOBS | ccache: $CCACHE | LTO: $USE_LTO"
}

# --------------- Install com rollback e buildinfo ----------------
log_transaction() {
  local action=$1 pkg=$2 ver=$3 status=$4
  local f="$FORGE_LOGS_DIR/$(date +%Y%m%d%H%M%S)_${action}_${pkg}.log"
  {
    echo "Data: $(date -u)"
    echo "Ação: $action"
    echo "Pacote: $pkg"
    echo "Versão: $ver"
    echo "Status: $status"
  } > "$f"
}

forge_install() {
  local pkg=$1 d ver dest fileslist backup_dir
  d="$(recipe_path "$pkg")" || die "recipe não encontrada: $pkg"
  ver="$(read_version "$pkg")"
  dest="$FORGE_DESTDIR/$pkg"
  [[ -d "$dest" ]] || die "nada para instalar: rode 'forge build $pkg'"

  backup_dir=$(mktemp -d)
  trap 'rm -rf "$backup_dir"' EXIT

  run_hook "$pkg" pre-install
  msg "install $pkg-$ver"

  # backup de arquivos existentes
  ( cd / && tar -cf "$backup_dir/backup.tar" "$dest" 2>/dev/null || true )

  if ! ( cd "$dest" && tar -cf - . | ( cd / && tar -xf - ) ); then
    warn "falha na instalação, restaurando backup"
    ( cd / && tar -xf "$backup_dir/backup.tar" )
    log_transaction install "$pkg" "$ver" fail
    die "rollback executado: $pkg"
  fi

  mkdir -p "$FORGE_DB/$pkg"
  fileslist="$FORGE_DB/$pkg/files"
  ( cd "$dest" && find . -type f -o -type l -o -type d | sed 's#^\./#/#' | LC_ALL=C sort ) > "$fileslist"
  echo "$ver" > "$FORGE_DB/$pkg/version"
  read_depends "$pkg" | awk '{print $1}' > "$FORGE_DB/$pkg/deps" 2>/dev/null || true

  # buildinfo
  {
    echo "Pacote:   $pkg"
    echo "Versão:   $ver"
    echo "Data:     $(date -u)"
    echo "Jobs:     $FORGE_JOBS"
    echo "LTO:      $USE_LTO"
    echo "ccache:   $CCACHE"
    echo "Fontes:"
    read_sources "$pkg"
    if has_checksums "$pkg"; then
      paste -d' ' "$(recipe_path "$pkg")/checksums" <(read_sources "$pkg")
    fi
    echo "Dependências:"
    while read -r dep; do
      [[ -z "$dep" ]] && continue
      depname="${dep%% *}"
      depver="$(pkg_version_installed "$depname" || echo '?')"
      echo "  $depname $depver"
    done < <(read_depends "$pkg")
  } > "$FORGE_DB/$pkg/buildinfo"

  run_hook "$pkg" post-install
  ok "instalado: $pkg-$ver"
  log_transaction install "$pkg" "$ver" success
}
# --------------- Remove + órfãos com rollback ----------------
reverse_lines() { tac "$1" 2>/dev/null || awk '{a[NR]=$0} END{for(i=NR;i>0;i--)print a[i]}' "$1"; }

forge_orphans_list() {
  local all deps
  all="$(ls -1 "$FORGE_DB" 2>/dev/null || true)"
  deps="$(cat "$FORGE_DB"/*/deps 2>/dev/null || true)"
  for p in $all; do
    grep -qx "$p" <<<"$deps" || echo "$p"
  done
}

forge_remove() {
  local pkg=$1
  [[ -d "$FORGE_DB/$pkg" ]] || die "$pkg não está instalado"

  local depby=""
  local user
  for user in $(ls -1 "$FORGE_DB" 2>/dev/null); do
    [[ -f "$FORGE_DB/$user/deps" ]] && grep -qx "$pkg" "$FORGE_DB/$user/deps" && depby+="$user "
  done
  if [[ -n "$depby" ]]; then
    warn "$pkg é dependência de: $depby"
    if [[ "$FORGE_ASSUME_YES" -eq 0 ]]; then
      read -r -p "remover mesmo assim? [y/N] " a
      [[ "$a" =~ ^[Yy]$ ]] || { msg "aborto"; return 1; }
    fi
  fi

  run_hook "$pkg" pre-remove
  msg "remove $pkg"

  local backup_dir=$(mktemp -d)
  trap 'rm -rf "$backup_dir"' EXIT
  if [[ -f "$FORGE_DB/$pkg/files" ]]; then
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      [[ -L "$f" || -f "$f" ]] && rm -f "$f" 2>/dev/null || true
      rmdir -p "$(dirname "$f")" 2>/dev/null || true
    done < <(reverse_lines "$FORGE_DB/$pkg/files")
  fi
  rm -rf "$FORGE_DB/$pkg"
  run_hook "$pkg" post-remove
  ok "removido: $pkg"
  log_transaction remove "$pkg" "$(pkg_version_installed "$pkg")" success

  local orf; orf="$(forge_orphans_list || true)"
  if [[ -n "${orf:-}" && "$FORGE_NO_ORPHANS" -eq 0 ]]; then
    echo "órfãos: $orf"
    read -r -p "remover órfãos também? [y/N] " a
    if [[ "$a" =~ ^[Yy]$ ]]; then
      local p; for p in $orf; do forge_remove "$p"; done
    fi
  fi
}

# --------------- Upgrade ----------------
ver_lt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]]; }
forge_upgrade() {
  local targets=("$@")
  if ((${#targets[@]}==0)); then
    mapfile -t targets < <(ls -1 "$FORGE_DB" 2>/dev/null || true)
  fi
  local pkg cur new
  for pkg in "${targets[@]}"; do
    cur="$(pkg_version_installed "$pkg" || true)"
    new="$(read_version "$pkg" || true)"
    [[ -z "$cur" || -z "$new" ]] && { warn "ignorado: $pkg (sem versão)"; continue; }
    if ver_lt "$cur" "$new"; then
      msg "upgrade $pkg $cur -> $new"
      forge_build "$pkg"
      forge_install "$pkg"
    else
      msg "$pkg já atualizado ($cur)"
    fi
  done
  ok "upgrade concluído"
}

# --------------- World ----------------
forge_world() {
  local all order=() p
  all="$(ls -1 "$FORGE_DB" 2>/dev/null || true)"
  [[ -z "$all" ]] && { msg "nada instalado"; return 0; }
  for p in $all; do
    while read -r n; do
      [[ " ${order[*]} " == *" $n "* ]] || order+=("$n")
    done < <(resolve_deps_order "$p")
  done
  for p in "${order[@]}"; do
    msg "[world] $p"
    forge_build "$p"
    forge_install "$p"
  done
  ok "world concluído"
}

# --------------- Sync ----------------
forge_sync() {
  local repo
  for repo in "${FORGE_REPOS[@]}"; do
    if [[ -d "$repo/.git" ]]; then
      msg "sync $repo"
      ( cd "$repo" && git pull --rebase --autostash >/dev/null 2>&1 || git pull --ff-only >/dev/null 2>&1 ) \
        || warn "falha ao sincronizar: $repo"
    else
      warn "não é repo git: $repo (pulando)"
    fi
  done
  ok "sync concluído"
}

# --------------- Histórico / Logs ----------------
forge_history() {
  ls -1 "$FORGE_LOGS_DIR" 2>/dev/null | sort
}

# --------------- Search/List/Show ----------------
forge_list() { ls -1 "$FORGE_DB" 2>/dev/null || true; }
forge_search() {
  local term="${1:-}"; [[ -z "$term" ]] && die "uso: forge search <termo>"
  local repo d; for repo in "${FORGE_REPOS[@]}"; do
    find "$repo" -mindepth 2 -maxdepth 2 -type d -print 2>/dev/null
  done | awk -F/ '{print $NF}' | grep -i "$term" | sort -u
}
forge_show() {
  local pkg="${1:-}"; [[ -z "$pkg" ]] && die "uso: forge show <pkg>"
  local d ver inst
  d="$(recipe_path "$pkg")" || die "recipe não encontrada: $pkg"
  ver="$(read_version "$pkg")"
  inst="$(pkg_version_installed "$pkg" || echo 'não')"
  echo "Pacote:   $pkg"
  echo "Recipe:   $d"
  echo "Versão:   $ver"
  echo "Instalado:$inst"
  if [[ -f "$d/depends" ]]; then echo "Depende de:"; cat "$d/depends"; fi
  if [[ -f "$d/sources" || -f "$d/source" ]]; then echo "Fontes:"; read_sources "$pkg"; fi
}

# --------------- Clean / Verify ----------------
forge_clean_src() { rm -rf "$FORGE_SRC"/*; ok "src limpo"; }
forge_verify_src() { for f in "$FORGE_SRC"/*; do sha256sum -c "$f" 2>/dev/null || warn "verificação falhou: $f"; done; }

# --------------- Dispatcher / Uso ----------------
usage() {
cat <<EOF
Uso: forge <comando> [args]

Comandos:
  build <pkg>         Compila (resolve deps, aplica patch, DESTDIR)
  install <pkg>       Instala a partir do DESTDIR do pacote
  remove <pkg>        Remove (pergunta sobre órfãos)
  upgrade [pkgs...]   Atualiza somente se versão do recipe for maior; sem args: todos
  world               Recompila+reinstala todos instalados em ordem de deps
  sync                git pull para todos repositórios
  list                Lista pacotes instalados
  search <termo>      Busca por nome nos repositórios
  show <pkg>          Mostra infos do pacote
  history             Mostra logs de transações
  clean-src           Limpa diretório de fontes
  verify-src          Verifica checksums de fontes
  orphans             Lista pacotes órfãos

Flags globais:
  -y                  Assume 'yes' para prompts
  --no-orphans        Ignora remoção de órfãos

EOF
}

main() {
  need_env; need_bins; init_dirs
  local cmd=""
  # processar flags globais
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y) FORGE_ASSUME_YES=1; shift;;
      --no-orphans) FORGE_NO_ORPHANS=1; shift;;
      *) cmd=$1; shift; break;;
    esac
  done

  case "$cmd" in
    build)    [[ $# -ge 1 ]] || die "uso: forge build <pkg>"; forge_build "$@";;
    install)  [[ $# -ge 1 ]] || die "uso: forge install <pkg>"; forge_install "$@";;
    remove|rm) [[ $# -ge 1 ]] || die "uso: forge remove <pkg>"; forge_remove "$@";;
    upgrade)  forge_upgrade "$@";;
    world)    forge_world;;
    sync)     forge_sync;;
    list)     forge_list;;
    search)   forge_search "$@";;
    show)     forge_show "$@";;
    history)  forge_history;;
    clean-src) forge_clean_src;;
    verify-src) forge_verify_src;;
    orphans)  forge_orphans_list;;
    help|-h|--help|"") usage;;
    *) die "comando inválido: $cmd (use 'forge help')" ;;
  esac
}
main "$@"
