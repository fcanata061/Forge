#!/bin/sh
# forge — gerenciador de pacotes estilo KISS (minimalista, porém sólido)

set -eu

# ========== Config (tudo pode ser sobrescrito via ambiente ou ~/.profile) ==========
: "${FORGE_DB:=${HOME}/.local/forge}"                    # estado local (instalados, logs, cache)
: "${FORGE_INSTALLED:=${FORGE_DB}/installed}"            # banco de instalados
: "${FORGE_LOGS:=${FORGE_DB}/logs}"                      # logs detalhados por pacote
: "${FORGE_SOURCES:=${FORGE_DB}/sources}"                # cache de tarballs/patches
: "${FORGE_BUILD:=${FORGE_DB}/build}"                    # área de build (workdir + DESTDIR)
: "${FORGE_BINPKGS:=${FORGE_DB}/binpkgs}"                # pacotes binários opcionais
: "${FORGE_REPO_DIRS:=${HOME}/forge/repo}"               # lista ":"-separada de repositórios locais
: "${FORGE_CLONE_BASE:=${HOME}/forge/repos}"             # onde clonar remotos (se usar na sync)
: "${FORGE_JOBS:=$(command -v nproc >/dev/null 2>&1 && nproc || echo 1)}"
: "${FORGE_COLOR:=1}"                                    # 1=on, 0=off
: "${FORGE_QUIET:=0}"                                    # menos verboso no stdout (log vai p/ arquivo)
: "${FORGE_SPINNER:=1}"                                  # 1=mostrar spinner em comandos longos

# cria estrutura
mkdir -p "$FORGE_INSTALLED" "$FORGE_LOGS" "$FORGE_SOURCES" "$FORGE_BUILD" "$FORGE_BINPKGS" "$FORGE_CLONE_BASE"

# ========== Cores/UX ==========
if [ "$FORGE_COLOR" = "1" ] && [ -t 1 ]; then
  C_BOLD="$(printf '\033[1m')" C_RED="$(printf '\033[31m')" C_GRN="$(printf '\033[32m')"
  C_YLW="$(printf '\033[33m')" C_BLU="$(printf '\033[34m')" C_RST="$(printf '\033[0m')"
else
  C_BOLD=""; C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_RST=""
fi

log_line() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "${FORGE_LOGS}/forge.log"; }
say() { [ "${FORGE_QUIET}" = "1" ] || printf "${C_GRN}[forge]${C_RST} %s\n" "$*"; log_line "$*"; }
warn() { printf "${C_YLW}[forge] WARN:${C_RST} %s\n" "$*" >&2; log_line "WARN: $*"; }
die() { printf "${C_RED}[forge] ERRO:${C_RST} %s\n" "$*" >&2; log_line "ERRO: $*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "comando requerido não encontrado: $1"; }

# spinner leve
spin_run() {
  # uso: spin_run "Mensagem..." comando args...
  local msg="$1"; shift
  [ "$FORGE_SPINNER" = "1" ] && [ -t 1 ] && local sp='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  [ "$FORGE_SPINNER" = "1" ] && [ -t 1 ] && printf "${C_BLU}%s${C_RST} " "$msg"
  if [ "$FORGE_SPINNER" = "1" ] && [ -t 1 ]; then
    ("$@" ) &
    pid=$!
    i=0
    while kill -0 $pid 2>/dev/null; do
      i=$(((i+1)%10))
      printf "\r${C_BLU}%s ${C_RST}%s" "$msg" "$(printf %s "$sp" | cut -c $i)"
      sleep 0.1
    done
    wait $pid
    printf "\r${C_BLU}%s${C_RST} %s\n" "$msg" "${C_GRN}ok${C_RST}"
  else
    "$@"
  fi
}

# ========== Repositórios ==========
# FORGE_REPO_DIRS aceita múltiplos caminhos ":"-separados. (Somente diretórios locais nesta versão.)
split_colon() { # imprime cada campo numa linha
  echo "$1" | awk -F: '{for(i=1;i<=NF;i++) if($i!="") print $i}'
}

recipe_dir() { # encontra diretório do pacote (primeiro que bater)
  local pkg="$1" dir
  while read -r dir; do
    # categorias livres: base/pkg, extra/pkg, etc.
    hit="$(find "$dir" -mindepth 2 -maxdepth 2 -type d -name "$pkg" 2>/dev/null | head -n1 || true)"
    [ -n "$hit" ] && { printf '%s\n' "$hit"; return 0; }
  done <<EOF
$(split_colon "$FORGE_REPO_DIRS")
EOF
  return 1
}

# ========== Metadados de pacote ==========
pkg_version() { local d; d="$(recipe_dir "$1")" || return 1; tr -d ' \t\r\n' < "$d/version"; }
pkg_deps()    { local d; d="$(recipe_dir "$1")" || return 0; awk 'NF{print $1}' "$d/depends" 2>/dev/null || true; }

# estado/paths
pkg_state_dir() { echo "${FORGE_INSTALLED}/$1"; }
pkg_files()     { echo "$(pkg_state_dir "$1")/files"; }
pkg_installed_ver() { [ -f "$(pkg_state_dir "$1")/version" ] && cat "$(pkg_state_dir "$1")/version" || echo ""; }
pkg_build_root(){ echo "${FORGE_BUILD}/$1"; }
pkg_destdir()   { echo "${FORGE_BUILD}/$1/_dest"; }
pkg_log()       { echo "${FORGE_LOGS}/$1.log"; }
pkg_binpath()   { echo "${FORGE_BINPKGS}/$1-$(pkg_version "$1").tar.xz"; }

# ========== Resolução de dependências (DFS + ordem topológica) ==========
resolve_deps_order() {
  # entrada: lista de pacotes; saída: ordem topológica única (deps antes dos pais)
  need awk
  _seen=""; _order=""
  _dfs() {
    local p="$1" d
    case " ${_seen} " in *" $p "*) return;; esac
    _seen="${_seen} $p"
    for d in $(pkg_deps "$p"); do _dfs "$d"; done
    _order="${_order} $p"
  }
  for x in "$@"; do _dfs "$x"; done
  for x in $_order; do echo "$x"; done | awk '!seen[$0]++'
}

# ========== Hooks ==========
# hooks por pacote: pre-build, post-build, pre-install, post-install, pre-remove, post-remove
run_hook() {
  local pkg="$1" hook="$2" d
  d="$(recipe_dir "$pkg")" || return 0
  [ -x "$d/$hook" ] || return 0
  say "hook $hook ($pkg)"
  "$d/$hook"
}

# ajuda
usage() {
cat <<EOF
uso: forge <comando> [args]

comandos:
  sync                      - sincroniza todos os repositórios (git pull)
  build <pkg>               - resolve deps e compila pacote (gera binário opcional)
  install <pkg>             - instala pacote (usa DESTDIR do build)
  remove <pkg>              - remove pacote (usa lista de arquivos)
  show <pkg>                - exibe info de pkg (versões, deps)
  list                      - lista instalados
  search <padrão>           - busca por pacotes nos repositórios
  orphans [--auto|--list]   - lista/remove pacotes órfãos
  world                     - recompila+reinstala todo o sistema em ordem de deps
  upgrade                   - atualiza somente se a versão do repo for maior
  help                      - mostra esta ajuda

variáveis úteis:
  FORGE_REPO_DIRS='/repo/base:/repo/x11:/repo/extra'   (lista ':'-separada)
  FORGE_DB, FORGE_INSTALLED, FORGE_BUILD, FORGE_SOURCES, FORGE_BINPKGS, FORGE_LOGS
  FORGE_JOBS (padrão: nproc), FORGE_COLOR=1, FORGE_QUIET=0, FORGE_SPINNER=1
EOF
}
# ========== Download / integridade (checksums opcionais) ==========
download_sources() {
  local pkg="$1" d url f i=0
  d="$(recipe_dir "$pkg")" || die "receita não encontrada: $pkg"
  [ -f "$d/sources" ] || return 0
  need curl
  while IFS= read -r url || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    f="${FORGE_SOURCES}/${url##*/}"
    if [ ! -f "$f" ]; then
      say "baixando $(basename "$f")"
      spin_run "download $(basename "$f")" \
        sh -c "curl -L --fail --retry 3 --continue-at - '$url' -o '$f'"
    fi
    i=$((i+1))
  done < "$d/sources"

  # checksums (sha256) na mesma ordem do sources (opcional)
  if [ -f "$d/checksums" ]; then
    need sha256sum
    paste -d' ' "$d/checksums" "$d/sources" | while read -r sum link; do
      [ -z "$sum" ] && continue
      f="${FORGE_SOURCES}/${link##*/}"
      sha256sum -c <(echo "$sum  $f") || die "checksum falhou: $f"
    done
  fi
}

# ========== Unpack + patches ==========
unpack_and_patch() {
  local pkg="$1" d w src_main=""
  d="$(recipe_dir "$pkg")"; w="$(pkg_build_root "$pkg")"
  rm -rf "$w"; mkdir -p "$w"
  [ -f "$d/sources" ] || { echo "$w"; return 0; }

  while IFS= read -r link || [ -n "$link" ]; do
    [ -z "$link" ] && continue
    f="${FORGE_SOURCES}/${link##*/}"
    case "$f" in
      *.tar.*|*.tgz|*.tbz2|*.txz)
        say "extraindo $(basename "$f")"
        (cd "$w" && tar -xf "$f")
        [ -z "$src_main" ] && src_main="$(find "$w" -mindepth 1 -maxdepth 1 -type d | head -n1 || echo "$w")"
        ;;
      *.patch) : ;; # patches geralmente ficam em patches/, mas suportamos se listado
      *) cp -a "$f" "$w/";;
    esac
  done < "$d/sources"

  [ -z "$src_main" ] && src_main="$w"
  # aplicar patches do diretório patches/
  if [ -d "$d/patches" ]; then
    need patch
    ( cd "$src_main"
      for p in "$d"/patches/*.patch; do
        [ -f "$p" ] || continue
        say "patch $(basename "$p")"
        patch -p1 < "$p"
      done
    )
  fi
  printf '%s\n' "$src_main"
}

# ========== Build (com hooks, logs e paralelismo) ==========
do_build_only() {
  local pkg="$1" d v src stage log
  d="$(recipe_dir "$pkg")" || die "receita não encontrada: $pkg"
  v="$(pkg_version "$pkg")"
  log="$(pkg_log "$pkg")"
  stage="$(pkg_destdir "$pkg")"

  # deps (build) — compila/instala deps se não instaladas
  for dep in $(pkg_deps "$pkg"); do
    [ -d "$(pkg_state_dir "$dep")" ] || { do_build_only "$dep"; do_install_only "$dep"; }
  done

  download_sources "$pkg"
  src="$(unpack_and_patch "$pkg")"
  rm -rf "$stage"; mkdir -p "$stage"

  run_hook "$pkg" "pre-build"
  say "build $pkg-$v"
  MAKEFLAGS="-j${FORGE_JOBS}"
  export MAKEFLAGS DESTDIR="$stage"
  { 
    set -x
    ( cd "$src" && [ -x "$d/build" ] && "$d/build" || sh "$d/build" )
  } >"$log" 2>&1 || { tail -n 60 "$log" >&2; die "falha no build ($pkg). veja $log"; }
  run_hook "$pkg" "post-build"

  # gerar binário opcional (tar.xz do stage)
  local bin; bin="$(pkg_binpath "$pkg")"
  ( cd "$stage" && tar -cJf "$bin" . ) || true
}

# ========== Install (com tracking de arquivos + hooks) ==========
do_install_only() {
  local pkg="$1" v stage state files log
  v="$(pkg_version "$pkg")" || die "sem versão: $pkg"
  stage="$(pkg_destdir "$pkg")"
  state="$(pkg_state_dir "$pkg")"
  files="$(pkg_files "$pkg")"
  log="$(pkg_log "$pkg")"

  [ -d "$stage" ] || die "nada para instalar; rode 'forge build $pkg'"

  run_hook "$pkg" "pre-install"
  say "install $pkg-$v"
  mkdir -p "$state"
  : >"$files"

  # copiar preservando atributos; registrar manifesto
  # instalando com tar para minimizar edge cases de cp -a
  ( cd "$stage" && tar -cf - . ) | ( cd / && tar -xf - )
  ( cd "$stage" && find . -type f -o -type l -o -type d | sed 's#^\./#/#' | LC_ALL=C sort ) > "$files"

  printf '%s\n' "$v" > "$state/version"
  # registra deps efetivas do repo no momento
  { for d in $(pkg_deps "$pkg"); do echo "$d"; done; } > "$state/depends" 2>/dev/null || true

  run_hook "$pkg" "post-install"
  say "instalado: $pkg-$v"
  echo "[installed $pkg-$v]" >> "$log"
}

# ========== Remove (com hooks e confirmação de órfãos) ==========
revdeps_of() {
  # quem depende de $1?
  local target="$1" p
  for p in $(ls -1 "$FORGE_INSTALLED" 2>/dev/null || true); do
    [ -f "$(pkg_state_dir "$p")/depends" ] && grep -qx "$target" "$(pkg_state_dir "$p")/depends" && printf '%s\n' "$p" || true
  done
}

do_remove() {
  local pkg="$1" state files
  state="$(pkg_state_dir "$pkg")"
  [ -d "$state" ] || die "$pkg não está instalado"

  # se alguém depende, avisa
  local users; users="$(revdeps_of "$pkg" | tr '\n' ' ' || true)"
  if [ -n "$users" ]; then
    warn "$pkg é dependência de: $users"
    printf "remover assim mesmo? [y/N] "; read ans; case "$ans" in y|Y) :;; *) say "aborto"; return 1;; esac
  fi

  run_hook "$pkg" "pre-remove"
  files="$(pkg_files "$pkg")"
  say "removendo $pkg"
  if [ -f "$files" ]; then
    # remove arquivos e tenta limpar dirs vazios
    tac "$files" 2>/dev/null || tail -r "$files" 2>/dev/null || awk '{a[NR]=$0} END{for(i=NR;i>0;i--)print a[i]}' "$files" | \
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      [ -L "$f" ] || [ -f "$f" ] && rm -f "$f" 2>/dev/null || true
      d="$(dirname "$f")"; rmdir -p "$d" 2>/dev/null || true
    done
  fi
  rm -rf "$state"
  run_hook "$pkg" "post-remove"
  say "removido: $pkg"
}

# ========== Search / Info / Lista ==========
do_search() {
  local pat="$1" dir
  while read -r dir; do
    find "$dir" -mindepth 2 -maxdepth 2 -type d -name "*$pat*" -printf '%P\n' 2>/dev/null || true
  done <<EOF
$(split_colon "$FORGE_REPO_DIRS")
EOF
}

do_info() {
  local pkg="$1" d v iv
  d="$(recipe_dir "$pkg")" || die "receita não encontrada: $pkg"
  v="$(pkg_version "$pkg")"
  iv="$(pkg_installed_ver "$pkg")"
  printf "pacote : %s\nversão : %s\ninstal.: %s\n" "$pkg" "$v" "$( [ -n "$iv" ] && echo "$iv" || echo "não" )"
  printf "deps   : %s\n" "$(pkg_deps "$pkg" | tr '\n' ' ' )"
  printf "repo   : %s\n" "$d"
}

do_list_installed() { ls -1 "$FORGE_INSTALLED" 2>/dev/null | LC_ALL=C sort || true; }

# ========== Órfãos (avançado) ==========
list_orphans() {
  # órfão = instalado que não é requerido por ninguém (e não está protegido)
  local base="${FORGE_BASE_PACKAGES:-}" p users
  for p in $(do_list_installed); do
    case " $base " in *" $p "*) continue;; esac
    users="$(revdeps_of "$p" || true)"
    [ -z "$users" ] && echo "$p"
  done
}

do_orphans() {
  local mode="${1-}"
  local list; list="$(list_orphans || true)"
  [ -z "$list" ] && { say "sem órfãos"; return 0; }
  case "$mode" in
    --auto) for p in $list; do do_remove "$p"; done ;;
    --list|"") printf '%s\n' "$list" ;;
    *) die "uso: forge orphans [--auto|--list]";;
  esac
}

# ========== World (rebuild ordenado) ==========
do_world() {
  local all order p
  all="$(do_list_installed)"
  [ -z "$all" ] && { say "nada instalado"; return 0; }
  # mescla ordem topológica para todos
  order=""
  for p in $all; do
    for n in $(resolve_deps_order "$p"); do
      case " $order " in *" $n "*) :;; *) order="$order $n";; esac
    done
  done
  for p in $order; do
    say "[world] $p"
    do_build_only "$p"
    do_install_only "$p"
  done
}

# ========== Upgrade (somente versões maiores) ==========
ver_gt() {
  # compara $1 > $2 usando sort -V (se existir), senão lexicográfico
  if command -v sort >/dev/null 2>&1 && printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1 | grep -qx "$1"; then
    [ "$1" != "$2" ] && return 0 || return 1
  else
    [ "$1" \> "$2" ] && [ "$1" != "$2" ]
  fi
}
do_upgrade() {
  local p inst repo
  for p in $(do_list_installed); do
    inst="$(pkg_installed_ver "$p" || true)"
    repo="$(pkg_version "$p" || true)"
    [ -z "$repo" ] && continue
    if [ -z "$inst" ] || ver_gt "$repo" "$inst"; then
      say "upgrade $p: ${inst:-none} -> $repo"
      do_build_only "$p"
      do_install_only "$p"
    fi
  done
}

# ========== Sync (git pull em todos os repositórios locais) ==========
do_sync() {
  local dir
  while read -r dir; do
    [ -d "$dir/.git" ] || { warn "não é git: $dir (pulando)"; continue; }
    say "sync $dir"
    ( cd "$dir" && git pull --rebase --autostash || git pull --ff-only ) >/dev/null 2>&1 || warn "falha ao sincronizar $dir"
  done <<EOF
$(split_colon "$FORGE_REPO_DIRS")
EOF
  say "sync concluído"
}

# ========== Dispatcher ==========
main() {
  local cmd="${1-}"; shift || true
  case "${cmd:-}" in
    help|-h|--help) usage ;;
    sync)           do_sync ;;
    build)          [ $# -eq 1 ] || die "uso: forge build <pkg>";  for x in $(resolve_deps_order "$1"); do do_build_only "$x"; done ;;
    install)        [ $# -eq 1 ] || die "uso: forge install <pkg>";for x in $(resolve_deps_order "$1"); do do_install_only "$x"; done ;;
    remove)         [ $# -eq 1 ] || die "uso: forge remove <pkg>"; do_remove "$1" ;;
    show|info)      [ $# -eq 1 ] || die "uso: forge show <pkg>";   do_info "$1" ;;
    list)           do_list_installed ;;
    search)         [ $# -eq 1 ] || die "uso: forge search <padrão>"; do_search "$1" ;;
    orphans)        do_orphans "${1-}";;
    world)          do_world ;;
    upgrade)        do_upgrade ;;
    *)              usage; [ -n "${cmd-}" ] && die "comando desconhecido: $cmd" ;;
  esac
}
main "$@"
# ========== Órfãos (avançado) ==========
list_orphans() {
  # órfão = instalado que não é requerido por ninguém (e não está protegido)
  local base="${FORGE_BASE_PACKAGES:-}" p users
  for p in $(do_list_installed); do
    case " $base " in *" $p "*) continue;; esac
    users="$(revdeps_of "$p" || true)"
    [ -z "$users" ] && echo "$p"
  done
}

do_orphans() {
  local mode="${1-}"
  local list; list="$(list_orphans || true)"
  [ -z "$list" ] && { say "sem órfãos"; return 0; }
  case "$mode" in
    --auto) for p in $list; do do_remove "$p"; done ;;
    --list|"") printf '%s\n' "$list" ;;
    *) die "uso: forge orphans [--auto|--list]";;
  esac
}

# ========== World (rebuild ordenado) ==========
do_world() {
  local all order p
  all="$(do_list_installed)"
  [ -z "$all" ] && { say "nada instalado"; return 0; }
  # mescla ordem topológica para todos
  order=""
  for p in $all; do
    for n in $(resolve_deps_order "$p"); do
      case " $order " in *" $n "*) :;; *) order="$order $n";; esac
    done
  done
  for p in $order; do
    say "[world] $p"
    do_build_only "$p"
    do_install_only "$p"
  done
}

# ========== Upgrade (somente versões maiores) ==========
ver_gt() {
  # compara $1 > $2 usando sort -V (se existir), senão lexicográfico
  if command -v sort >/dev/null 2>&1 && printf '%s\n%s\n' "$2" "$1" | sort -V | tail -n1 | grep -qx "$1"; then
    [ "$1" != "$2" ] && return 0 || return 1
  else
    [ "$1" \> "$2" ] && [ "$1" != "$2" ]
  fi
}
do_upgrade() {
  local p inst repo
  for p in $(do_list_installed); do
    inst="$(pkg_installed_ver "$p" || true)"
    repo="$(pkg_version "$p" || true)"
    [ -z "$repo" ] && continue
    if [ -z "$inst" ] || ver_gt "$repo" "$inst"; then
      say "upgrade $p: ${inst:-none} -> $repo"
      do_build_only "$p"
      do_install_only "$p"
    fi
  done
}

# ========== Sync (git pull em todos os repositórios locais) ==========
do_sync() {
  local dir
  while read -r dir; do
    [ -d "$dir/.git" ] || { warn "não é git: $dir (pulando)"; continue; }
    say "sync $dir"
    ( cd "$dir" && git pull --rebase --autostash || git pull --ff-only ) >/dev/null 2>&1 || warn "falha ao sincronizar $dir"
  done <<EOF
$(split_colon "$FORGE_REPO_DIRS")
EOF
  say "sync concluído"
}

# ========== Dispatcher ==========
main() {
  local cmd="${1-}"; shift || true
  case "${cmd:-}" in
    help|-h|--help) usage ;;
    sync)           do_sync ;;
    build)          [ $# -eq 1 ] || die "uso: forge build <pkg>";  for x in $(resolve_deps_order "$1"); do do_build_only "$x"; done ;;
    install)        [ $# -eq 1 ] || die "uso: forge install <pkg>";for x in $(resolve_deps_order "$1"); do do_install_only "$x"; done ;;
    remove)         [ $# -eq 1 ] || die "uso: forge remove <pkg>"; do_remove "$1" ;;
    show|info)      [ $# -eq 1 ] || die "uso: forge show <pkg>";   do_info "$1" ;;
    list)           do_list_installed ;;
    search)         [ $# -eq 1 ] || die "uso: forge search <padrão>"; do_search "$1" ;;
    orphans)        do_orphans "${1-}";;
    world)          do_world ;;
    upgrade)        do_upgrade ;;
    *)              usage; [ -n "${cmd-}" ] && die "comando desconhecido: $cmd" ;;
  esac
}
main "$@" 
