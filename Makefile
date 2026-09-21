IMAGE ?= ldap-debian:test
TESTS ?=

.PHONY: build lint certs test

build:
	docker build -t $(IMAGE) .

lint:
	shellcheck -x scripts/* tests/*.sh tests/fixtures/*.sh tests/integration/*.sh
	docker run --rm -i hadolint/hadolint < Dockerfile

certs:
	tests/fixtures/gen-certs.sh

test: build certs
	BUILD=0 IMAGE=$(IMAGE) tests/run.sh $(TESTS)
