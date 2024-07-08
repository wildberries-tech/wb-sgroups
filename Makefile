export GOSUMDB=off
export GO111MODULE=on

$(value $(shell [ ! -d "$(CURDIR)/bin" ] && mkdir -p "$(CURDIR)/bin"))
GOBIN?=$(CURDIR)/bin

export GOBIN

GO?=$(shell which go)
GIT_TAG:=$(shell git describe --exact-match --abbrev=0 --tags 2> /dev/null)
GIT_HASH:=$(shell git log --format="%h" -n 1 2> /dev/null)
GIT_BRANCH:=$(shell git branch 2> /dev/null | grep '*' | cut -f2 -d' ')
GO_VERSION:=$(shell go version | sed -E 's/.* go(.*) .*/\1/g')
BUILD_TS:=$(shell date +%FT%T%z)
VERSION:=$(shell cat ./VERSION 2> /dev/null | sed -n "1p")

PROJECT:=HBF
APP?=sgroups
APP_NAME?=$(PROJECT)/$(APP)
APP_VERSION:=$(if $(VERSION),$(VERSION),$(if $(GIT_TAG),$(GIT_TAG),$(GIT_BRANCH)))




.PHONY: help
help: ##display this help
	@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)


GOLANGCI_BIN:=$(GOBIN)/golangci-lint
GOLANGCI_REPO?=https://github.com/golangci/golangci-lint
GOLANGCI_LATEST_VERSION?= $(shell git ls-remote --tags --refs --sort='v:refname' $(GOLANGCI_REPO)|tail -1|egrep -o "v[0-9]+.*")
ifneq ($(wildcard $(GOLANGCI_BIN)),)
	GOLANGCI_CUR_VERSION=v$(shell $(GOLANGCI_BIN) --version|sed -E 's/.*version (.*) built.*/\1/g')	
else
	GOLANGCI_CUR_VERSION=
endif

.PHONY: .install-linter
.install-linter:	
ifeq ($(filter $(GOLANGCI_CUR_VERSION), $(GOLANGCI_LATEST_VERSION)),)
	$(info Installing GOLANGCI-LINT $(GOLANGCI_LATEST_VERSION)...)
	@curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(GOBIN) $(GOLANGCI_LATEST_VERSION)
	@chmod +x $(GOLANGCI_BIN)
else
	@echo 1 >/dev/null
endif

.PHONY: lint
lint: | go-deps ##run full lint
	@echo full lint... && \
	$(MAKE) .install-linter && \
	$(GOLANGCI_BIN) cache clean && \
	$(GOLANGCI_BIN) run --timeout=120s --config=$(CURDIR)/.golangci.yaml -v $(CURDIR)/... &&\
	echo -=OK=-


.PHONY: go-deps
go-deps: ##install golang dependencies
	@echo check go modules dependencies ... && \
	$(GO) mod tidy && \
 	$(GO) mod vendor && \
	$(GO) mod verify && \
	echo -=OK=-

.PHONY: .install-grpc-plugins
.install-grpc-plugins:
	@echo - ensure GRPC plugins are installed
ifeq ($(wildcard $(GOBIN)/protoc-gen-grpc-gateway),)
	@echo install \"protoc-gen-grpc-gateway\" && \
	$(GO) install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway
endif
ifeq ($(wildcard $(GOBIN)/protoc-gen-openapiv2),)
	@echo install \"protoc-gen-openapiv2\" && \
	$(GO) install github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2
endif
ifeq ($(wildcard $(GOBIN)/protoc-gen-go),)
	@echo install \"protoc-gen-go\" && \
	$(GO) install google.golang.org/protobuf/cmd/protoc-gen-go
endif
ifeq ($(wildcard $(GOBIN)/protoc-gen-go-grpc),)
	@echo install \"protoc-gen-go-grpc\" && \
	$(GO) install google.golang.org/grpc/cmd/protoc-gen-go-grpc
endif
ifeq ($(wildcard $(GOBIN)/protoc-gen-connect-go),)
	@echo install \"protoc-gen-connect-go\" && \
	$(GO) install connectrpc.com/connect/cmd/protoc-gen-connect-go@latest
endif	


proto_dirs := common sgroups
.PHONY: generate-api
generate-api: | .install-grpc-plugins ##generate API from proto files
	@(\
	apis=$(CURDIR)/protos && \
	dest=$(CURDIR)/pkg/api && \
	PATH=$(PATH):$(GOBIN):/usr/include:/usr/local/include && \
	echo generating API in \"$$dest\" ... && \
	for p in $(proto_dirs); do \
		rm -rf $$dest/$$p 2>/dev/null ;\
		for v in $$apis/$$p/*.proto; do \
			echo  "  - " \"$$p/$$(basename $$v)\" ;\
			protoc \
				-I $(CURDIR)/vendor/github.com/grpc-ecosystem/grpc-gateway/v2/ \
				-I $(CURDIR)/internal/3d-party \
				-I $(CURDIR)/pkg/api \
				--go_opt=paths=source_relative \
				--go-grpc_opt=paths=source_relative \
				--go_out $$dest \
				--go-grpc_out $$dest \
				--proto_path=$$apis \
				--grpc-gateway_out $$dest \
				--grpc-gateway_opt paths=source_relative \
				--grpc-gateway_opt logtostderr=true \
				--grpc-gateway_opt standalone=false \
				--openapiv2_out $$dest \
				--openapiv2_opt logtostderr=true \
				--connect-go_out=$$dest \
				--connect-go_opt=paths=source_relative \
				"$$v" ||\
			exit 1;\
		done; \
	done; \
	echo -=OK=- ;\
	)

.PHONY: test-tf-provider
test-tf-provider: ##run tests for tf provider only
	@echo running sgroups-tf-provider tests... && \
	$(GO) clean -testcache && \
	$(GO) test -v ./internal/app/sgroups-tf-provider && \
	echo -=OK=-

.PHONY: test
test: ##run tests
	@echo running tests... && \
	$(GO) clean -testcache && \
	$(GO) test -v ./... && \
	echo -=OK=-


platform?=$(shell $(GO) env GOOS)/$(shell $(GO) env GOARCH)
os?=$(strip $(filter linux darwin,$(word 1,$(subst /, ,$(platform)))))
arch?=$(strip $(filter amd64 arm64,$(word 2,$(subst /, ,$(platform)))))
OUT?=$(CURDIR)/bin/$(APP)
APP_IDENTITY?=github.com/H-BF/corlib/app/identity
LDFLAGS?=-X '$(APP_IDENTITY).Name=$(APP_NAME)'\
         -X '$(APP_IDENTITY).Version=$(APP_VERSION)'\
         -X '$(APP_IDENTITY).BuildTS=$(BUILD_TS)'\
         -X '$(APP_IDENTITY).BuildBranch=$(GIT_BRANCH)'\
         -X '$(APP_IDENTITY).BuildHash=$(GIT_HASH)'\
         -X '$(APP_IDENTITY).BuildTag=$(GIT_TAG)'\

.PHONY: sg-service
sg-service: | go-deps ##build sg service. Usage: make sg-service [platform=<linux|darwin>/<amd64|arm64>]
ifeq ($(and $(os),$(arch)),)
	$(error bad param 'platform'; usage: platform=<os>/<arch>; where <os> = linux|darwin ; <arch> = amd64|arm64)
endif
	@echo build '$(APP)' for OS/ARCH='$(os)'/'$(arch)' ... && \
	echo into '$(OUT)' && \
	env GOOS=$(os) GOARCH=$(arch) CGO_ENABLED=0 \
	$(GO) build -ldflags="$(LDFLAGS)" -o $(OUT) $(CURDIR)/cmd/$(APP) &&\
	echo -=OK=-

.PHONY: to-nft
to-nft: | go-deps ##build NFT processor. Usage: make to-nft [platform=linux/<amd64|arm64>]
to-nft: APP=to-nft
to-nft: os=linux
to-nft: 
ifneq ('$(os)','linux')
	$(error 'os' should be 'linux')
endif
ifeq ($(and $(os),$(arch)),)
	$(error bad param 'platform'; usage: platform=linux/<arch>; where <arch> = amd64|arm64)
endif
	@echo build \"$(APP)\" for OS/ARCH=\"$(os)/$(arch)\" ... && \
	echo into \"$(OUT)\" && \
	env GOOS=$(os) GOARCH=$(arch) CGO_ENABLED=0 \
	$(GO) build -ldflags="$(LDFLAGS)" -o $(OUT) $(CURDIR)/cmd/$(APP) &&\
	echo -=OK=- 

 
.PHONY: sgroups-tf-v2	
sgroups-tf-v2: | go-deps ##build SGroups Terraform provider V2 
sgroups-tf-v2: APP=sgroups-tf-v2
sgroups-tf-v2: OUT=$(CURDIR)/bin/terraform-provider-sgroups
sgroups-tf-v2:
	@echo build \"$(APP)\" for OS/ARCH=\"$(os)/$(arch)\" ... && \
	echo into \"$(OUT)\" && \
	env GOOS=$(os) GOARCH=$(arch) CGO_ENABLED=0 \
	$(GO) build -ldflags="$(LDFLAGS)" -o $(OUT) $(CURDIR)/cmd/$(APP) &&\
	echo -=OK=- 


GOOSE_REPO:=https://github.com/pressly/goose
GOOSE_LATEST_VERSION:= $(shell git ls-remote --tags --refs --sort='v:refname' $(GOOSE_REPO)|tail -1|egrep -o "v[0-9]+.*")
GOOSE:=$(GOBIN)/goose
ifneq ($(wildcard $(GOOSE)),)
	GOOSE_CUR_VERSION?=$(shell $(GOOSE) -version|egrep -o "v[0-9\.]+")	
else
	GOOSE_CUR_VERSION?=
endif
.PHONY: .install-goose
.install-goose: 
ifeq ($(filter $(GOOSE_CUR_VERSION), $(GOOSE_LATEST_VERSION)),)
	@echo installing \'goose\' $(GOOSE_LATEST_VERSION) util... && \
	GOBIN=$(GOBIN) $(GO) install github.com/pressly/goose/v3/cmd/goose@$(GOOSE_LATEST_VERSION)
else
	@echo >/dev/null
endif

# example PG_URI=postgres://postgres:master@localhost:5432/sg?sslmode=disable
PG_MIGRATIONS?=$(CURDIR)/internal/registry/sgroups/pg/migrations
PG_URI?=
.PHONY: sgroups-pg-migrations
sgroups-pg-migrations: ##run SGroups Postgres migrations
ifneq ($(PG_URI),)
	@$(MAKE) .install-goose && \
	cd $(PG_MIGRATIONS) && \
	$(GOOSE) -table=sgroups_db_ver postgres $(PG_URI) up
else
	$(error need define PG_URI environment variable)
endif	
	

