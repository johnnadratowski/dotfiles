BINARY := {{BUILD_TARGET}}
BINARY_LINUX := ${BINARY}-linux
PACKAGEDIR := $(CURDIR)
SCRIPTSDIR := $(CURDIR)/scripts
GLIDE := glide
GO := go
VERSION := $(cat ./VERSION)
GIT_HASH := $(git rev-parse HEAD)
BUILD_TIMESTAMP := $(date '+%%Y-%%m-%%dT%%H:%%M:%%S-%%Z')
HOSTNAME := $(hostname)
LDFLAGS := -ldflags "-X cmd.Version=${VERSION} -X cmd.GitHash=${GIT_HASH} -X cmd.BuildTimestamp=${BUILD_TIMESTAMP} cmd.BuildHostname=${HOSTNAME}"
SQLITE_FILE := /tmp/tasks.sqlite
VAGRANT_DIR := /{{FOLDER_NAME}}

define rmfile
    if [ -f $(1) ] ; then rm -f $(1) ; fi
endef

all: ${BINARY} ${BINARY_LINUX}

# Builds the project
${BINARY}: glide.lock
	$(GO) build ${LDFLAGS} -o ${BINARY}

${BINARY_LINUX}: glide.lock
	vagrant ssh -c 'cd ${VAGRANT_DIR}; GOPATH=/go/ go build ${LDFLAGS} -o ${BINARY}-linux'

build:
	make ${BINARY}

.git/hooks/pre-commit:
	ln -s ../../scripts/git/pre-commit .git/hooks/pre-commit

# generate glide lock file by installing install
glide.lock: .git/hooks/pre-commit
	$(call rmfile, ./glide.lock)
	$(GLIDE) install

update:
	$(GLIDE) update

# Cleans our project: deletes binaries
clean:
	$(call rmfile, ${BINARY})
	$(call rmfile, ${BINARY_LINUX})

watch:
	watcher

.PHONY: build clean update