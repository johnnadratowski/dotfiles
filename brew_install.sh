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

brew tap homebrew/cask-fonts

echo "Update brew"
brew update

set -x
brew install  -f      \
  asciidoctor         \
  awscli              \
  diff-so-fancy       \
  drovio              \
  entr                \
  fd                  \
  fzf                 \
  go                  \
  htop                \
  karabiner-elements  \
  lua                 \
  macpass             \
  mercurial           \
  moreutils           \
  ncdu                \
  node                \
  noti                \
  npm                 \
  rust                \
  prettyping          \
  python3             \
  the_silver_searcher \
  tesseract           \
  tldr                \
  tmux                \
  tree                \
  vim                 \
  visual-studio-code  \
  zsh

brew install --cask font-fira-code

set +x

# fzf - To install useful key bindings and fuzzy completion:
$(brew --prefix)/opt/fzf/install

# Ensure mac does key repeats on key hold
defaults write -g ApplePressAndHoldEnabled -bool false

# Update magic mouse sensitivity to be higher than normal maximum
defaults write -g com.apple.mouse.scaling  5.0
