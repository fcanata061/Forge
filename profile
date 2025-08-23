# ==============================
# .profile do Forge
# ==============================

# Diretório base do Forge
export FORGE_HOME="$HOME/.forge"

# Repositórios locais (podem ser múltiplos)
# Estrutura: cada repo deve ter subpastas com pacotes e recipes
# Ex: $HOME/forge-repo/base/gcc
export FORGE_REPOS=(
    "$HOME/forge-repo/base"
    "$HOME/forge-repo/x11"
    "$HOME/forge-repo/desktop"
    "$HOME/forge-repo/extras"
)

# Diretórios internos
export FORGE_DB="$FORGE_HOME/db"         # banco de pacotes instalados
export FORGE_LOG="$FORGE_HOME/log"       # logs detalhados
export FORGE_SRC="$FORGE_HOME/src"       # sources baixados
export FORGE_BUILD="$FORGE_HOME/build"   # diretório de build
export FORGE_HOOKS="$FORGE_HOME/hooks"   # hooks globais

# Comportamento
export FORGE_JOBS="$(nproc)"             # paralelismo (jobs de make)
export FORGE_COLOR=1                     # habilita cores
export FORGE_STRIP=1                     # strip binários após build
export FORGE_GIT_SYNC=1                  # habilita sync via git
export FORGE_LOG_LEVEL=debug             # níveis: info, warn, error, debug

# Editor padrão para recipes
export FORGE_EDITOR="nano"

# PATH: adiciona o forge no sistema
export PATH="$HOME/bin:$PATH"

# ==============================
# Autocompletion
# ==============================
# Ativa se bash-completion estiver instalado
if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
fi

# Completion para bash
_forge_complete() {
    local cur prev cmds pkgs
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"
    cmds="build install remove upgrade world sync search show list orphans"

    case "$prev" in
        build|install|remove|upgrade|show)
            pkgs=$(ls -1 "$FORGE_DB" 2>/dev/null)
            COMPREPLY=( $(compgen -W "$pkgs" -- "$cur") )
            return 0
            ;;
        orphans)
            COMPREPLY=( $(compgen -W "list auto" -- "$cur") )
            return 0
            ;;
    esac

    COMPREPLY=( $(compgen -W "$cmds" -- "$cur") )
    return 0
}
complete -F _forge_complete forge

# Completion para zsh (se disponível)
if type compdef &>/dev/null; then
    _forge_zsh_complete() {
        reply=($(build install remove upgrade world sync search show list orphans))
    }
    compdef _forge_zsh_complete forge
fi
