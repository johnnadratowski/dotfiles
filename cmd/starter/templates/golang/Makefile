BINARY := {{BUILD_TARGET}}
BINARY_LINUX := ${BINARY}-linux
PACKAGEDIR := $(CURDIR)
SCRIPTSDIR := $(CURDIR)/scripts
GLIDE := glide
GO := go
VERSION := $(shell cat ./VERSION)
GIT_HASH := $(shell git rev-parse HEAD)
BUILD_TIMESTAMP := $(shell date +%Y-%m-%dT%H:%M:%S-%Z)
HOSTNAME := $(shell hostname)
LDFLAGS := -ldflags "-X {{IMPORT_PATH}}/cmd.Version=${VERSION} -X {{IMPORT_PATH}}/cmd.GitHash=${GIT_HASH} -X {{IMPORT_PATH}}/cmd.BuildTimestamp=${BUILD_TIMESTAMP} -X {{IMPORT_PATH}}/cmd.BuildHostname=${HOSTNAME}"
VAGRANT_DIR := /go/src/{{IMPORT_PATH}}

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
	$(GLIDE) install

update:
	$(GLIDE) update

# Cleans our project: deletes binaries
clean:
	$(call rmfile, ${BINARY})
	$(call rmfile, ${BINARY_LINUX})

reset:
	$(call rmfile, ./glide.lock)
	make clean

watch:
	watcher

.PHONY: build clean reset update