#!/usr/bin/env bash
set -e

if ! which xcode-select; then
	echo "Install xcode"
	xcode-select --install
fi

if ! which brew; then
	echo "Install brew"
	ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
fi

echo "Update brew"
brew update

set -x
brew install          \
  asciidoctor         \
  awscli              \
  diff-so-fancy       \
  entr                \
  fd                  \
  fzf                 \
  go                  \
  htop                \
  lua                 \
  mercurial           \
  ncdu                \
  node                \
  noti                \
  npm                 \
  prettyping          \
  python3             \
  the_silver_searcher \
  tldr                \
  tmux                \
  vim                 \
  zsh
brew cask install copyq
brew cask install hammerspoon
brew cask install macpass
brew cask install visual-studio-code
brew cask install karabiner-elements
 > /dev/null
set +x

# fzf - To install useful key bindings and fuzzy completion:
$(brew --prefix)/opt/fzf/install

# Ensure mac does key repeats on key hold
defaults write -g ApplePressAndHoldEnabled -bool false

# Update magic mouse sensitivity to be higher than normal maximum
defaults write -g com.apple.mouse.scaling  5.0
