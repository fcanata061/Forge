#!/bin/sh
# Forge - Gerenciador de pacotes minimalista inspirado no KISS

# Variáveis principais (configure no ~/.profile)
: "${FORGE_REPO:=$HOME/forge/repo}"
: "${FORGE_DB:=$HOME/forge/db}"
: "${FORGE_LOG:=$HOME/forge/log}"
: "${DESTDIR:=$HOME/forge/dest}"

# Função de ajuda
forge_help() {
    cat <<EOF
Forge - comandos disponíveis:

  forge build <pkg>     - Compila um pacote e prepara para instalar
  forge install <pkg>   - Instala pacote compilado
  forge remove <pkg>    - Remove um pacote
  forge show <pkg>      - Mostra informações do pacote
  forge list            - Lista pacotes instalados
  forge orphans         - Lista pacotes órfãos
  forge world           - Recompila todo o sistema
  forge sync            - Sincroniza repositório Git
  forge upgrade         - Atualiza pacotes para versões mais novas
  forge help            - Mostra esta ajuda
EOF
}

# Logging
forge_log() {
    mkdir -p "$FORGE_LOG"
    echo "[$(date '+%F %T')] $*" >> "$FORGE_LOG/forge.log"
}

# Resolução de dependências recursiva
forge_resolve_deps() {
    pkg=$1
    local seen=$2
    local deps

    [ -n "$(echo "$seen" | grep -w "$pkg")" ] && return

    repo=$(find "$FORGE_REPO" -type d -name "$pkg" | head -n1)
    [ -z "$repo" ] && echo "Pacote não encontrado: $pkg" && exit 1

    if [ -f "$repo/deps" ]; then
        deps=$(cat "$repo/deps")
        for d in $deps; do
            forge_resolve_deps "$d" "$seen $pkg"
        done
    fi
    echo "$pkg"
}

# Compilar
forge_build() {
    pkg=$1
    echo "[*] Build: $pkg"

    pkgs=$(forge_resolve_deps "$pkg")
    for p in $pkgs; do
        repo=$(find "$FORGE_REPO" -type d -name "$p" | head -n1)
        cd "$repo" || exit 1
        mkdir -p "$DESTDIR"
        sh build
    done
    forge_log "Build $pkg"
}

# Instalar com rastreamento de arquivos
forge_install() {
    pkg=$1
    dest="$DESTDIR"

    echo "[*] Instalando $pkg em /"
    cd "$FORGE_REPO"/**/"$pkg" || exit 1
    rm -rf "$dest"
    mkdir -p "$dest"

    sh build install

    mkdir -p "$FORGE_DB/$pkg"
    : > "$FORGE_DB/$pkg/files"

    find "$dest" -type f -o -type l -o -type d | while read f; do
        rel=$(echo "$f" | sed "s|^$dest||")
        cp -a "$f" "/$rel"
        echo "/$rel" >> "$FORGE_DB/$pkg/files"
    done

    if [ -f version ]; then
        cat version > "$FORGE_DB/$pkg/version"
    fi

    echo "[OK] Instalado: $pkg"
    forge_log "Install $pkg"
}

# Remover com pergunta sobre órfãos
forge_remove() {
    pkg=$1
    if [ ! -d "$FORGE_DB/$pkg" ]; then
        echo "Pacote $pkg não está instalado"
        exit 1
    fi

    echo "[*] Removendo $pkg"
    while read f; do
        [ -e "$f" ] && rm -rf "$f"
    done < "$FORGE_DB/$pkg/files"

    rm -rf "$FORGE_DB/$pkg"
    echo "[OK] Removido: $pkg"
    forge_log "Remove $pkg"

    orphans=$(forge_orphans)
    if [ -n "$orphans" ]; then
        echo "Órfãos detectados: $orphans"
        printf "Deseja removê-los também? [s/N] "
        read ans
        [ "$ans" = "s" ] && for o in $orphans; do forge_remove "$o"; done
    fi
}

# Mostrar informações
forge_show() {
    pkg=$1
    echo "Pacote: $pkg"
    [ -f "$FORGE_DB/$pkg/version" ] && \
        echo "Versão instalada: $(cat "$FORGE_DB/$pkg/version")"
    [ -f "$FORGE_REPO"/**/"$pkg"/version ] && \
        echo "Versão repo: $(cat "$FORGE_REPO"/**/"$pkg"/version)"
    [ -f "$FORGE_REPO"/**/"$pkg"/deps ] && \
        echo "Dependências: $(cat "$FORGE_REPO"/**/"$pkg"/deps)"
}

# Listar pacotes instalados
forge_list() {
    ls "$FORGE_DB"
}

# Detectar órfãos
forge_orphans() {
    all=$(ls "$FORGE_DB")
    used=""
    for p in $all; do
        repo=$(find "$FORGE_REPO" -type d -name "$p" | head -n1)
        [ -f "$repo/deps" ] && used="$used $(cat "$repo/deps")"
    done
    for p in $all; do
        echo "$used" | grep -qw "$p" || echo "$p"
    done
}

# Recompilar todo o sistema
forge_world() {
    for pkg in $(ls "$FORGE_DB"); do
        forge_build "$pkg" && forge_install "$pkg"
    done
}

# Upgrade apenas se versão maior
forge_upgrade() {
    for pkg in $(ls "$FORGE_DB"); do
        instver=$(cat "$FORGE_DB/$pkg/version" 2>/dev/null || echo "0")
        repo=$(find "$FORGE_REPO" -type d -name "$pkg" | head -n1)
        [ -z "$repo" ] && continue
        repover=$(cat "$repo/version" 2>/dev/null || echo "0")

        if [ "$repover" \> "$instver" ]; then
            echo ">>> Upgrade $pkg: $instver -> $repover"
            forge_build "$pkg" && forge_install "$pkg"
        fi
    done
}

# Sincronizar repositório Git
forge_sync() {
    cd "$FORGE_REPO" || exit 1
    git pull --ff-only
    forge_log "Sync repo"
}

# Dispatcher
cmd=$1; shift || true
case "$cmd" in
    build) forge_build "$@";;
    install) forge_install "$@";;
    remove) forge_remove "$@";;
    show) forge_show "$@";;
    list) forge_list;;
    orphans) forge_orphans;;
    world) forge_world;;
    upgrade) forge_upgrade;;
    sync) forge_sync;;
    help|"") forge_help;;
    *) echo "Comando inválido: $cmd"; forge_help;;
esac
