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
LDFLAGS := -ldflags "-X {{IMPORT_PATH}}/src/cmd.Version=${VERSION} -X {{IMPORT_PATH}}/src/cmd.GitHash=${GIT_HASH} -X {{IMPORT_PATH}}/src/cmd.BuildTimestamp=${BUILD_TIMESTAMP} -X {{IMPORT_PATH}}/src/cmd.BuildHostname=${HOSTNAME}"
VAGRANT_DIR := /go/src/{{IMPORT_PATH}}

define rmfile
    if [ -f $(1) ] ; then rm -f $(1) ; fi
endef

all: build build-linux

build:
	make ${BINARY}

build-linux:
	make ${BINARY_LINUX}

# Builds the project
${BINARY}: glide.lock
	$(GO) build ${LDFLAGS} -o ${BINARY}

${BINARY_LINUX}: glide.lock
	docker run --rm -v $(CURDIR):/go/src/{{IMPORT_PATH}} -w /go/src/{{IMPORT_PATH}} golang go build ${LDFLAGS} -o ${BINARY_LINUX}

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

.PHONY: build build-linux clean reset update watch