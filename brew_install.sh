#!/user/bin/bash
echo "Install xcode"
xcode-select --install

echo "Install brew"
ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"

echo "Update brew"
brew update

set -x
brew install          \
  asciidoctor         \
  awscli              \
  batch               \
  diff-so-fancy       \
  entr                \
  fd                  \
  fzf                 \
  go                  \
  hammerspoon         \
  htop                \
  lua                 \
  mercurial           \
  ncdu                \
  node                \
  npm                 \
  prettyping          \
  python3             \
  the_silver_searcher \
  tldr                \
  tmux                \
  vim                 \
  zsh
set +x

# fzf - To install useful key bindings and fuzzy completion:
$(brew --prefix)/opt/fzf/install