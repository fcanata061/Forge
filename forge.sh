#!/bin/sh
# forge - gerenciador de pacotes minimalista (evoluído)

set -e

# =========[ Core Variáveis - vêm do ~/.profile ]=========
# FORGE_REPOS=("$HOME/forge-repo/base" "$HOME/forge-repo/extra")
# FORGE_DB=/var/lib/forge
# FORGE_LOG=/var/log/forge
# FORGE_DESTDIR=/tmp/forge-dest
# FORGE_JOBS=$(nproc)

# =========[ Utils: Cores, Log, Spinner ]=========
c_red="\033[1;31m"; c_grn="\033[1;32m"; c_yel="\033[1;33m"; c_cya="\033[1;36m"; c_rst="\033[0m"

msg() { printf "${c_cya}==>${c_rst} %s\n" "$*"; }
ok()  { printf "${c_grn}✔${c_rst} %s\n" "$*"; }
err() { printf "${c_red}✘${c_rst} %s\n" "$*" >&2; exit 1; }
warn(){ printf "${c_yel}!${c_rst} %s\n" "$*\n"; }

log() {
    pkg=$1; shift
    mkdir -p "$FORGE_LOG"
    "$@" >"$FORGE_LOG/$pkg.log" 2>&1 || {
        err "Falha ao executar comando. Veja $FORGE_LOG/$pkg.log"
    }
}

spinner() {
    pid=$!
    spin='-\|/'
    i=0
    while kill -0 $pid 2>/dev/null; do
        i=$(( (i+1) %4 ))
        printf "\r[%c] " "${spin:$i:1}"
        sleep .1
    done
    printf "\r   \r"
}

# =========[ Funções de DB ]=========
pkg_installed() { [ -f "$FORGE_DB/$1/version" ]; }

pkg_version() {
    [ -f "$FORGE_DB/$1/version" ] && cat "$FORGE_DB/$1/version"
}

pkg_files() {
    [ -f "$FORGE_DB/$1/files" ] && cat "$FORGE_DB/$1/files"
}

pkg_deps() {
    [ -f "$FORGE_DB/$1/deps" ] && cat "$FORGE_DB/$1/deps"
}

record_install() {
    pkg=$1; ver=$2; files=$3
    mkdir -p "$FORGE_DB/$pkg"
    echo "$ver" > "$FORGE_DB/$pkg/version"
    cat "$files" > "$FORGE_DB/$pkg/files"
    [ -f "deps" ] && cp deps "$FORGE_DB/$pkg/deps"
}

remove_record() {
    rm -rf "$FORGE_DB/$1"
}

# =========[ Localizar pacotes nos repositórios ]=========
find_pkg() {
    for repo in "${FORGE_REPOS[@]}"; do
        [ -d "$repo/$1" ] && echo "$repo/$1" && return 0
    done
    return 1
}
# =========[ Helpers de repositório e recipe ]=========
recipe_path() { # $1=pkg -> ecoa caminho completo da recipe
    local pkg=$1
    for repo in "${FORGE_REPOS[@]}"; do
        # aceita estrutura repo/<categoria>/<pkg>
        local hit
        hit="$(find "$repo" -mindepth 2 -maxdepth 2 -type d -name "$pkg" 2>/dev/null | head -n1)"
        [[ -n "$hit" ]] && { echo "$hit"; return 0; }
    done
    return 1
}

read_version() { local d; d="$(recipe_path "$1")" || return 1; tr -d ' \t\r\n' < "$d/version"; }
read_depends() { local d; d="$(recipe_path "$1")" || return 0; [[ -f "$d/depends" ]] && awk 'NF{print $1}' "$d/depends"; }

# =========[ Resolução de dependências (ordem topológica) ]=========
_res_seen=(); _res_order=()
_res_mark_seen() { _res_seen+=("$1"); }
_res_is_seen() { local x; for x in "${_res_seen[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
_res_push_order() { _res_order+=("$1"); }

_resolve_one() {
    local p=$1
    _res_is_seen "$p" && return 0
    _res_mark_seen "$p"
    local d
    while read -r d 2>/dev/null; do [[ -n "$d" ]] && _resolve_one "$d"; done < <(read_depends "$p")
    _res_push_order "$p"
}

resolve_deps_order() {
    _res_seen=(); _res_order=()
    local p
    for p in "$@"; do _resolve_one "$p"; done
    printf '%s\n' "${_res_order[@]}" | awk 'NF && !seen[$0]++'
}

# =========[ Hooks ]=========
run_hook() { # $1=pkg $2=hook-name
    local pkg=$1 hook=$2 d
    d="$(recipe_path "$pkg")" || return 0
    [[ -x "$d/$hook" ]] || return 0
    msg "hook $hook ($pkg)"
    "$d/$hook"
}

# =========[ Download de fontes + checksums ]=========
download_sources() {
    local pkg=$1 d src url out
    d="$(recipe_path "$pkg")" || err "recipe não encontrada: $pkg"
    [[ -f "$d/sources" ]] || return 0
    command -v curl >/dev/null || err "curl não encontrado"

    while IFS= read -r src || [[ -n "$src" ]]; do
        [[ -z "$src" ]] && continue
        out="$FORGE_SOURCES/${src##*/}"
        if [[ ! -f "$out" ]]; then
            msg "baixando $(basename "$out")"
            curl -L --fail --retry 3 --continue-at - "$src" -o "$out" 2>&1 | tee -a "$FORGE_LOG/$pkg.log"
        fi
    done < "$d/sources"

    # Verificação opcional por sha256
    if [[ -f "$d/checksums" ]]; then
        command -v sha256sum >/dev/null || err "sha256sum não encontrado"
        paste -d' ' "$d/checksums" "$d/sources" | while read -r sum link; do
            [[ -z "$sum" ]] && continue
            out="$FORGE_SOURCES/${link##*/}"
            printf '%s  %s\n' "$sum" "$out" | sha256sum -c - || err "checksum falhou: $out"
        done
    fi
}

# =========[ Extrair + aplicar patches ]=========
unpack_and_patch() {
    local pkg=$1 d w main=""
    d="$(recipe_path "$pkg")" || err "recipe não encontrada: $pkg"
    w="$FORGE_BUILD/$pkg"
    rm -rf "$w"; mkdir -p "$w"

    if [[ -f "$d/sources" ]]; then
        while IFS= read -r link || [[ -n "$link" ]]; do
            [[ -z "$link" ]] && continue
            local f="$FORGE_SOURCES/${link##*/}"
            case "$f" in
                *.tar.*|*.tgz|*.tbz2|*.txz|*.tar) (cd "$w" && tar -xf "$f");;
                *.zip) (cd "$w" && unzip -q "$f");;
                *.patch) : ;;  # patch listado é ignorado aqui; usamos $d/patches/*.patch
                *) cp -a "$f" "$w/";;
            esac
        done < "$d/sources"
    fi

    # diretório principal (primeiro dir extraído) ou o próprio $w
    main="$(find "$w" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    [[ -z "$main" ]] && main="$w"

    if [[ -d "$d/patches" ]]; then
        command -v patch >/dev/null || err "patch não encontrado"
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

# =========[ Build ]=========
forge_build() {
    local pkg=$1 d ver src dest
    d="$(recipe_path "$pkg")" || err "recipe não encontrada: $pkg"
    ver="$(read_version "$pkg")"

    # construir deps (se não instaladas)
    while read -r dep 2>/dev/null; do
        [[ -z "$dep" ]] && continue
        if ! pkg_installed "$dep"; then
            forge_build "$dep"
            forge_install "$dep"
        fi
    done < <(read_depends "$pkg")

    download_sources "$pkg"
    src="$(unpack_and_patch "$pkg")"
    dest="${FORGE_DESTDIR:-/tmp/forge-dest}/$pkg"
    rm -rf "$dest"; mkdir -p "$dest"

    export DESTDIR="$dest"
    export MAKEFLAGS="-j${FORGE_JOBS:-1}"

    run_hook "$pkg" pre-build
    msg "build $pkg-$ver"
    if [[ -x "$d/build" ]]; then
        ( cd "$src"; "$d/build" ) >> "$FORGE_LOG/$pkg.log" 2>&1 || err "falha no build ($pkg). veja $FORGE_LOG/$pkg.log"
    else
        ( cd "$src"; sh "$d/build" ) >> "$FORGE_LOG/$pkg.log" 2>&1 || err "falha no build ($pkg). veja $FORGE_LOG/$pkg.log"
    fi
    run_hook "$pkg" post-build
    ok "build concluído: $pkg-$ver"
}

# =========[ Install (com tracking de arquivos) ]=========
forge_install() {
    local pkg=$1 d ver dest fileslist
    d="$(recipe_path "$pkg")" || err "recipe não encontrada: $pkg"
    ver="$(read_version "$pkg")"
    dest="${FORGE_DESTDIR:-/tmp/forge-dest}/$pkg"
    [[ -d "$dest" ]] || err "nada para instalar: rode 'forge build $pkg'"

    run_hook "$pkg" pre-install
    msg "install $pkg-$ver"

    # copiar usando tar (mais robusto que múltiplos cp -a)
    ( cd "$dest" && tar -cf - . ) | ( cd / && tar -xf - )

    mkdir -p "$FORGE_DB/$pkg"
    fileslist="$FORGE_DB/$pkg/files"
    ( cd "$dest" && find . -type f -o -type l -o -type d | sed 's#^\./#/#' | LC_ALL=C sort ) > "$fileslist"
    echo "$ver" > "$FORGE_DB/$pkg/version"
    read_depends "$pkg" > "$FORGE_DB/$pkg/deps" 2>/dev/null || true

    run_hook "$pkg" post-install
    ok "instalado: $pkg-$ver"
}

# =========[ Remove (usa manifesto + hooks) ]=========
forge_remove() {
    local pkg=$1
    [[ -d "$FORGE_DB/$pkg" ]] || err "$pkg não está instalado"

    # aviso se alguém depende dele
    local user depby
    depby=""
    for user in $(ls -1 "$FORGE_DB" 2>/dev/null); do
        [[ -f "$FORGE_DB/$user/deps" ]] && grep -qx "$pkg" "$FORGE_DB/$user/deps" && depby+="$user "
    done
    if [[ -n "$depby" ]]; then
        warn "$pkg é dependência de: $depby"
        read -r -p "remover mesmo assim? [y/N] " a
        [[ "$a" =~ ^[Yy]$ ]] || { msg "aborto"; return 1; }
    fi

    run_hook "$pkg" pre-remove
    msg "remove $pkg"

    # remove na ordem inversa do manifesto e tenta limpar diretórios vazios
    if [[ -f "$FORGE_DB/$pkg/files" ]]; then
        tac "$FORGE_DB/$pkg/files" 2>/dev/null || \
        tail -r "$FORGE_DB/$pkg/files" 2>/dev/null || \
        awk '{a[NR]=$0} END{for(i=NR;i>0;i--)print a[i]}' "$FORGE_DB/$pkg/files" | \
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ -L "$f" || -f "$f" ]] && rm -f "$f" 2>/dev/null || true
            rmdir -p "$(dirname "$f")" 2>/dev/null || true
        done
    fi
    rm -rf "$FORGE_DB/$pkg"
    run_hook "$pkg" post-remove
    ok "removido: $pkg"

    # pergunta sobre órfãos (apenas listar aqui; modo auto fica na Parte 3)
    local orf
    orf="$(forge_orphans list)"
    if [[ -n "$orf" ]]; then
        echo "órfãos: $orf"
        read -r -p "remover órfãos também? [y/N] " a
        if [[ "$a" =~ ^[Yy]$ ]]; then
            for p in $orf; do forge_remove "$p"; done
        fi
    fi
}

# =========[ Sync (git pull em todos repositórios locais) ]=========
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

# =========[ World (rebuild instalado em ordem) ]=========
forge_world() {
    local all order p
    all="$(ls -1 "$FORGE_DB" 2>/dev/null || true)"
    [[ -z "$all" ]] && { msg "nada instalado"; return 0; }

    # ordem topológica consolidada
    order=()
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
# =========[ Version compare (retorna 0 se $1 < $2) ]=========
ver_lt() { [ "$(printf '%s\n%s' "$1" "$2" | sort -V | head -n1)" != "$2" ]; }

# =========[ Upgrade ]=========
forge_upgrade() {
    local pkg=$1 cur new
    cur="$(pkg_version "$pkg" 2>/dev/null || true)"
    new="$(read_version "$pkg" 2>/dev/null || true)"
    [[ -z "$cur" || -z "$new" ]] && { warn "pacote não encontrado: $pkg"; return; }
    if ver_lt "$cur" "$new"; then
        msg "upgrade $pkg $cur -> $new"
        forge_build "$pkg"
        forge_install "$pkg"
    else
        msg "$pkg já na versão mais recente ($cur)"
    fi
}

# =========[ Orphans ]=========
forge_orphans() {
    local mode=${1:-list} p used
    used=()
    for p in $(ls -1 "$FORGE_DB" 2>/dev/null); do
        [[ -f "$FORGE_DB/$p/deps" ]] && used+=($(cat "$FORGE_DB/$p/deps"))
    done

    local all="$(ls -1 "$FORGE_DB" 2>/dev/null)"
    local orf=()
    for p in $all; do
        [[ " ${used[*]} " == *" $p "* ]] || orf+=("$p")
    done

    case "$mode" in
        list) printf '%s\n' "${orf[@]}";;
        auto) for p in "${orf[@]}"; do forge_remove "$p"; done;;
        *) err "uso: forge orphans [list|auto]";;
    esac
}

# =========[ Search, show, list ]=========
forge_search() {
    local term=$1 repo d
    for repo in "${FORGE_REPOS[@]}"; do
        while IFS= read -r d; do
            pkg="${d##*/}"
            grep -qi "$term" <<< "$pkg" && echo "$pkg"
        done < <(find "$repo" -mindepth 2 -maxdepth 2 -type d)
    done | sort -u
}

forge_show() {
    local pkg=$1 d ver
    d="$(recipe_path "$pkg")" || err "recipe não encontrada: $pkg"
    ver="$(read_version "$pkg")"
    echo "Pacote: $pkg"
    echo "Versão: $ver"
    echo "Path: $d"
    [[ -f "$d/depends" ]] && { echo "Depende de:"; cat "$d/depends"; }
}

forge_list() { ls -1 "$FORGE_DB" 2>/dev/null || true; }

# =========[ Dispatcher CLI ]=========
usage() {
cat <<EOF
Uso: forge <comando> [args]

Comandos principais:
  build <pkg>      - compila pacote (e deps)
  install <pkg>    - instala pacote já compilado
  remove <pkg>     - remove pacote (pergunta sobre órfãos)
  upgrade <pkg>    - atualiza se versão for maior
  world            - recompila todos os instalados
  sync             - sincroniza todos os repositórios git
  search <termo>   - procura pacotes nos repositórios
  show <pkg>       - mostra info de pacote
  list             - lista pacotes instalados
  orphans [list|auto] - lida com pacotes órfãos

EOF
}

case "$1" in
    build) shift; forge_build "$@";;
    install) shift; forge_install "$@";;
    remove) shift; forge_remove "$@";;
    upgrade) shift; forge_upgrade "$@";;
    world) forge_world;;
    sync) forge_sync;;
    search) shift; forge_search "$@";;
    show) shift; forge_show "$@";;
    list) forge_list;;
    orphans) shift; forge_orphans "$@";;
    ""|-h|--help|help) usage;;
    *) err "comando inválido: $1";;
esac
