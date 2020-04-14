SHELL = /bin/bash

export GOPATH := $(shell pwd)/gopath

PEBBLE_PATH = $(GOPATH)/src/github.com/letsencrypt/pebble
HS = $(shell find src/ test/ -name '*.hs')

.PHONY: $(HS)

default:
	@echo "Use 'stack' as build tool. For details see 'README.md'."
	@echo "Makefile commands:"
	@echo "  make pebble"
	@echo "  make format-code"

pebble: pebble-get pebble-install pebble-cert-symlinks

pebble-get:
	go get -d -u github.com/letsencrypt/pebble/...

pebble-install:
	cd $(PEBBLE_PATH); go install ./...

pebble-cert-symlinks:
	ln -s  $(GOPATH)/src/github.com/letsencrypt/pebble/test/certs test/certs
	ln -s  $(GOPATH)/src/github.com/letsencrypt/pebble/test/config test/config

format-code: $(HS)

$(HS):
	-@hindent --sort-imports $@
	-@hlint -j --no-summary $@

