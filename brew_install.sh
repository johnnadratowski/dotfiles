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
  go                  \
  hammerspoon         \
  lua                 \
  mercurial           \
  node                \
  npm                 \
  python3             \
  the_silver_searcher \
  tmux                \
  vim                 \
  zsh
set +x