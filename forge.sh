#!/bin/bash
# forge - gerenciador de pacotes estilo KISS (minimalista, shell puro)

set -euo pipefail

# ========= CONFIG (padrões; pode sobrescrever por ambiente) =========
: "${FORGE_DB:=/var/db/forge}"
: "${FORGE_REPO_DIRS:=${FORGE_DB}/repo}"              # pode ser lista separada por ':' (ex: /x:/y)
: "${FORGE_SOURCES:=${FORGE_DB}/sources}"
: "${FORGE_BUILD:=${FORGE_DB}/build}"
: "${FORGE_BINPKGS:=${FORGE_DB}/binpkgs}"
: "${FORGE_INSTALLED:=${FORGE_DB}/installed}"
: "${FORGE_LOGS:=${FORGE_DB}/logs}"
: "${FORGE_COMPRESS_CMD:=tar -cJf}"                   # xz
: "${FORGE_EXTRACT:=tar -xf}"                         # tar detecta formato por extensão
: "${FORGE_CURL:=curl -L --fail --retry 3 --continue-at -}"
: "${FORGE_JOBS:=$(nproc)}"

umask 022

mkdir -p "$FORGE_DB" "$FORGE_SOURCES" "$FORGE_BUILD" "$FORGE_BINPKGS" "$FORGE_INSTALLED" "$FORGE_LOGS"

# ========= helpers =========
msg() { printf '[forge] %s\n' "$*"; }
die() { printf 'forge: ERRO: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "comando requerido não encontrado: $1"; }

is_root() { [ "$(id -u)" = "0" ]; }
join_by() { local IFS="$1"; shift; echo "$*"; }

# Encontrar diretório de receita do pacote em FORGE_REPO_DIRS
recipe_dir() {
  local pkg="$1" IFS=:
  for base in $FORGE_REPO_DIRS; do
    # procurar por */pkg (categoria livre)
    local hit
    hit="$(find "$base" -mindepth 2 -maxdepth 2 -type d -name "$pkg" 2>/dev/null | head -n1 || true)"
    [ -n "$hit" ] && { echo "$hit"; return 0; }
  done
  return 1
}

# Ler arquivo se existir, senão vazio
read_file() { [ -f "$1" ] && cat "$1" || true; }

# Lista dependências (uma por linha)
pkg_deps() { local d; d="$(recipe_dir "$1")" || return 0; read_file "$d/depends" | awk 'NF{print $1}'; }

# Ler versão
pkg_version() { local d; d="$(recipe_dir "$1")" || die "receita não encontrada: $1"; tr -d ' \t\r\n' < "$d/version"; }

# Caminhos utilitários
pkg_workdir() { echo "$FORGE_BUILD/$1"; }
pkg_stage()   { echo "$FORGE_BUILD/$1/_dest"; }
pkg_log()     { echo "$FORGE_LOGS/$1.log"; }
pkg_bin()     { echo "$FORGE_BINPKGS/$1-$(pkg_version "$1").tar.xz"; }
pkg_state_dir(){ echo "$FORGE_INSTALLED/$1"; }

# Manifesto de arquivos instalados
pkg_manifest_path(){ echo "$(pkg_state_dir "$1")/manifest"; }

# ========= resolução de dependências (recursiva, ordenada, sem duplicar) =========
resolve_deps_dfs() {
  # gera ordem topológica simples via DFS
  local pkg="$1"
  _forge_seen="${_forge_seen-}"
  _forge_stack="${_forge_stack-}"
  _forge_result="${_forge_result-}"

  _dfs() {
    local x="$1"
    case " ${_forge_seen} " in *" $x "*) return;; esac
    _forge_seen="$_forge_seen $x"
    local d
    for d in $(pkg_deps "$x"); do _dfs "$d"; done
    _forge_result="$_forge_result $x"
  }
  _dfs "$pkg"
  # output único por linha, sem repetição
  for p in $_forge_result; do echo "$p"; done | awk '!seen[$0]++'
}

# ========= download de fontes e verificação =========
download_sources() {
  local pkg="$1" dir src url i=0
  dir="$(recipe_dir "$pkg")" || die "receita não encontrada: $pkg"
  need curl
  while IFS= read -r url || [ -n "$url" ]; do
    [ -z "$url" ] && continue
    local base="${url##*/}"
    local out="$FORGE_SOURCES/$base"
    if [ ! -f "$out" ]; then
      msg "baixando $base"
      $FORGE_CURL "$url" -o "$out"
    fi
    i=$((i+1))
  done < "$dir/sources"

  # checksums (opcional: sha256) na mesma ordem do 'sources'
  if [ -f "$dir/checksums" ]; then
    need sha256sum
    paste -d' ' "$dir/checksums" "$dir/sources" | while read -r sum link; do
      [ -z "$sum" ] && continue
      local f="$FORGE_SOURCES/${link##*/}"
      sha256sum -c <(echo "$sum  $f") || die "checksum falhou: $f"
    done
  fi
}

# ========= extrair e aplicar patches =========
unpack_and_patch() {
  local pkg="$1" r w
  r="$(recipe_dir "$pkg")"; w="$(pkg_workdir "$pkg")"
  rm -rf "$w"; mkdir -p "$w"
  # extrair cada fonte (primeiro tarball vira src principal)
  local src_main=""
  while IFS= read -r link || [ -n "$link" ]; do
    [ -z "$link" ] && continue
    local f="$FORGE_SOURCES/${link##*/}"
    case "$f" in
      *.tar.*|*.tgz|*.tbz2|*.txz) 
         msg "extraindo $(basename "$f")"
         (cd "$w" && $FORGE_EXTRACT "$f")
         [ -z "$src_main" ] && src_main="$(find "$w" -mindepth 1 -maxdepth 1 -type d | head -n1)"
       ;;
      *.patch) : ;; # patches opcionais listados em 'sources' (normalmente ficam em patches/)
      *) cp -a "$f" "$w/";;
    esac
  done < "$r/sources"

  # se não detectou diretório, use o workdir
  [ -z "${src_main:-}" ] && src_main="$w"

  # aplicar patches do diretório patches/
  if [ -d "$r/patches" ]; then
    need patch
    ( cd "$src_main"
      for p in "$r"/patches/*.patch; do
        [ -f "$p" ] || continue
        msg "aplicando patch $(basename "$p")"
        patch -p1 < "$p"
      done
    )
  fi

  echo "$src_main"
}
# ========= build do pacote (com deps) =========
do_build_only() {
  local pkg="$1" r v src stage log
  r="$(recipe_dir "$pkg")" || die "receita não encontrada: $pkg"
  v="$(pkg_version "$pkg")"
  log="$(pkg_log "$pkg")"
  stage="$(pkg_stage "$pkg")"

  # build deps primeiro (se não instaladas)
  for dep in $(pkg_deps "$pkg"); do
    if [ ! -f "$(pkg_state_dir "$dep")/version" ]; then
      do_build_only "$dep"
      do_install_only "$dep"
    fi
  done

  download_sources "$pkg"
  src="$(unpack_and_patch "$pkg")"

  rm -rf "$stage"; mkdir -p "$stage"
  msg "build $pkg-$v"
  [ -x "$r/build" ] || die "arquivo 'build' não é executável em $r"
  # Ambiente padrão de build
  (
    set -e
    cd "$src"
    export DESTDIR="$stage"
    export MAKEFLAGS="-j${FORGE_JOBS}"
    bash "$r/build"
  ) |& tee "$log"

  # gerar binpkg (tar.xz)
  local bin="$(pkg_bin "$pkg")"
  ( cd "$stage" && $FORGE_COMPRESS_CMD "$bin" . ) 
  msg "binário gerado: $bin"

  # gerar manifesto (a partir do stage)
  ( cd "$stage" && find . -type f -o -type l | sed 's#^\./#/#' | LC_ALL=C sort ) > "$(pkg_workdir "$pkg")/manifest"
}

# ========= instalar (merge do binário) =========
do_install_only() {
  local pkg="$1" v bin state man
  v="$(pkg_version "$pkg")"
  bin="$(pkg_bin "$pkg")"
  [ -f "$bin" ] || die "binário não encontrado: $bin (rode 'forge build $pkg')"
  is_root || die "instalação requer root"

  state="$(pkg_state_dir "$pkg")"
  rm -rf "$state"; mkdir -p "$state"

  msg "instalando $pkg-$v"
  # extrair para /
  $FORGE_EXTRACT "$bin" -C /

  # gravar manifesto e metadados
  man="$(pkg_manifest_path "$pkg")"
  if [ -f "$(pkg_workdir "$pkg")/manifest" ]; then
    install -Dm644 "$(pkg_workdir "$pkg")/manifest" "$man"
  else
    # caso excepcional: gerar manifesto do próprio bin (menos preciso)
    tar -tf "$bin" | sed 's#^\./#/#; s#^#/#' | LC_ALL=C sort > "$man"
  fi
  install -Dm644 <(pkg_deps "$pkg") "$state/depends" || true
  install -Dm644 <(echo "$v") "$state/version"
}

# ========= remoção com base no manifesto =========
do_remove() {
  local pkg="$1" state man
  state="$(pkg_state_dir "$pkg")"
  [ -d "$state" ] || die "$pkg não está instalado"
  man="$(pkg_manifest_path "$pkg")"
  is_root || die "remoção requer root"

  # checar se é requerido por outros
  local revusers
  revusers="$(forge_revdeps "$pkg")"
  if [ -n "$revusers" ]; then
    msg "ATENÇÃO: $pkg é dependência de: $(echo "$revusers" | tr '\n' ' ')"
    read -r -p "remover assim mesmo? [y/N] " ans
    [[ "${ans:-N}" =~ ^[Yy]$ ]] || { msg "aborto"; return 1; }
  fi

  # remover na ordem reversa (arquivos antes, diretórios depois)
  if [ -f "$man" ]; then
    tac "$man" 2>/dev/null || tail -r "$man" 2>/dev/null || awk '{a[NR]=$0} END{for(i=NR;i>0;i--)print a[i]}' "$man" | \
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [ -L "$f" ] || [ -f "$f" ]; then rm -f "$f" 2>/dev/null || true; fi
      dir="$(dirname "$f")"; rmdir -p "$dir" 2>/dev/null || true
    done
  fi
  rm -rf "$state"
  msg "removido: $pkg"
}

# ========= info/list/search =========
do_info() {
  local pkg="$1" r v
  r="$(recipe_dir "$pkg")" || die "receita não encontrada: $pkg"
  v="$(pkg_version "$pkg")"
  echo "pacote : $pkg"
  echo "versão : $v"
  echo "instal.: $( [ -d "$(pkg_state_dir "$pkg")" ] && echo sim || echo não )"
  echo -n "deps   : "; pkg_deps "$pkg" | tr '\n' ' '; echo
  echo -n "fonte  : "; read_file "$r/sources" | paste -sd' ' -; echo
}

do_list_installed() {
  [ -d "$FORGE_INSTALLED" ] || return 0
  find "$FORGE_INSTALLED" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
}

do_search() {
  local pat="$1" IFS=:
  for base in $FORGE_REPO_DIRS; do
    find "$base" -mindepth 2 -maxdepth 2 -type d -name "*$pat*" -printf '%P\n' 2>/dev/null || true
  done | sort -u
}

# ========= reverse deps e órfãos =========
forge_revdeps() {
  local target="$1" p d users=""
  for p in $(do_list_installed); do
    for d in $(read_file "$(pkg_state_dir "$p")/depends"); do
      [ "$d" = "$target" ] && users="$users $p"
    done
  done
  echo "$users" | awk 'NF{for(i=1;i<=NF;i++)print $i}'
}

do_orphans() {
  # órfãos: instalados que não são requeridos por ninguém e não são "base"
  local base_set="${FORGE_BASE_PACKAGES:-}" # opcional: defina base via env
  for p in $(do_list_installed); do
    # p é base?
    case " $base_set " in *" $p "*) continue;; esac
    local users; users="$(forge_revdeps "$p")"
    [ -z "$users" ] && echo "$p"
  done
}
# ========= update / world =========
do_update() {
  # recompila e reinstala todos os instalados (ordem por deps)
  local all pkgs_order=""
  all="$(do_list_installed)"
  [ -z "$all" ] && { msg "nada instalado"; return 0; }

  # construir grafo simples via reutilização do resolve_deps_dfs por pacote
  # e mesclar mantendo unicidade e ordem
  for p in $all; do
    for n in $(resolve_deps_dfs "$p"); do
      case " $pkgs_order " in *" $n "*) :;; *) pkgs_order="$pkgs_order $n";; esac
    done
  done

  for p in $pkgs_order; do
    msg "[world] build $p"
    do_build_only "$p"
    msg "[world] install $p"
    do_install_only "$p"
  done
}

# ========= uso =========
usage() {
cat <<'EOF'
uso: forge <comando> [args]

comandos principais:
  build <pkg>       - baixa fontes, resolve deps, compila e gera binário
  install <pkg>     - instala binário gerado em /
  remove <pkg>      - remove pacote instalado (com confirmação se dependência)
  info <pkg>        - mostra versão, deps e fontes
  search <padrão>   - procura pacotes disponíveis no(s) repo(s)
  list              - lista pacotes instalados
  orphans           - lista pacotes órfãos (não requeridos)
  update            - recompila e reinstala todo o sistema (world)

variáveis úteis (podem ser exportadas):
  FORGE_REPO_DIRS   - diretórios de repositório (ex.: /x:/y:/z)
  FORGE_DB          - prefixo do banco do forge (default /var/db/forge)
  FORGE_JOBS        - paralelismo (default: nproc)
  FORGE_BASE_PACKAGES - lista de pacotes considerados "base" (ex.: "linux glibc gcc")

exemplos:
  forge search gcc
  forge build zlib && sudo forge install zlib
  sudo forge remove zlib
  forge info gcc
  forge list
  forge orphans
  sudo forge update
EOF
}

# ========= main =========
main() {
  local cmd="${1-}"; shift || true
  case "${cmd:-}" in
    build)   [ $# -eq 1 ] || die "uso: forge build <pkg>"; do_build_only "$1" ;;
    install) [ $# -eq 1 ] || die "uso: forge install <pkg>"; do_install_only "$1" ;;
    remove)  [ $# -eq 1 ] || die "uso: forge remove <pkg>"; do_remove "$1" ;;
    info)    [ $# -eq 1 ] || die "uso: forge info <pkg>"; do_info "$1" ;;
    list)    do_list_installed ;;
    search)  [ $# -eq 1 ] || die "uso: forge search <padrão>"; do_search "$1" ;;
    orphans) do_orphans ;;
    update)  do_update ;;
    ""|-h|--help|help) usage ;;
    *) die "comando desconhecido: $cmd (tente 'forge --help')" ;;
  esac
}
main "$@"
