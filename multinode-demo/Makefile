ZPR_ROOT ?=
ZPR_BUILDER_IMAGE ?= zpr-multinode-builder
CANDIDATE_OUTPUT_PARENT ?=
CANDIDATE_RELEASE_ID ?=

.PHONY: all linux-amd64 linux-arm64 ph visaservice compiler dashboard check-zpr-root clean candidate-preflight

all: ph visaservice compiler dashboard

candidate-preflight:
	python3 packaging/build-isolated-candidate.py --preflight-report --dry-run \
		--source-root "$(ZPR_ROOT)" --output-parent "$(CANDIDATE_OUTPUT_PARENT)" \
		--release-id "$(CANDIDATE_RELEASE_ID)"

linux-arm64: check-zpr-root
	docker build --platform linux/arm64 -t zpr-multinode-arm64-builder \
		-f Dockerfile.build-linux .
	docker run --rm --platform linux/arm64 -e ZPR_ROOT=/work \
		-v "$(abspath $(ZPR_ROOT)):/work" zpr-multinode-arm64-builder \
		/bin/bash /work/zpr-demo/multinode-demo/build-linux-arm64.sh
	cd "$(ZPR_ROOT)/zpr-visaservice/zpr-dashboard" && \
		GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
		-ldflags '-s -w' -o "$(CURDIR)/bin/linux-arm64/zpr-web-dashboard" ./cmd/zpr-web-dashboard

linux-amd64: check-zpr-root
	docker build --platform linux/amd64 -t $(ZPR_BUILDER_IMAGE) \
		-f Dockerfile.build-linux .
	docker run --rm --platform linux/amd64 -e ZPR_ROOT=/work \
		-v "$(ZPR_ROOT):/work" $(ZPR_BUILDER_IMAGE) \
		/bin/bash /work/zpr-demo/multinode-demo/build-linux-amd64.sh
	mkdir -p bin
	cd "$(ZPR_ROOT)/zpr-visaservice/zpr-dashboard" && \
		GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath \
		-ldflags '-s -w' -o bin/zpr-dashboard ./cmd/zpr-dashboard && \
		GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath \
		-ldflags '-s -w' -o bin/zpr-web-dashboard ./cmd/zpr-web-dashboard
	cp "$(ZPR_ROOT)/zpr-visaservice/zpr-dashboard/bin/zpr-dashboard" \
		"$(ZPR_ROOT)/zpr-visaservice/zpr-dashboard/bin/zpr-web-dashboard" bin/

check-zpr-root:
	@test -n "$(ZPR_ROOT)" || { \
		echo "ZPR_ROOT must point to the directory containing the ZPR repositories" >&2; \
		exit 1; \
	}
	@test -d "$(ZPR_ROOT)/zpr-core" || { \
		echo "ZPR_ROOT=$(ZPR_ROOT) does not contain zpr-core" >&2; \
		exit 1; \
	}

ph: check-zpr-root
	mkdir -p bin
	cd "$(ZPR_ROOT)/zpr-core/adapter/ph" && cargo build --release
	cd "$(ZPR_ROOT)/zpr-core" && cargo build --release -p ph-cli
	cp "$(ZPR_ROOT)/zpr-core/target/release/ph" \
		"$(ZPR_ROOT)/zpr-core/target/release/ph-cli" bin/

visaservice: check-zpr-root
	mkdir -p bin
	cd "$(ZPR_ROOT)/zpr-visaservice" && cargo build --release
	cp "$(ZPR_ROOT)/zpr-visaservice/target/release/vs" \
		"$(ZPR_ROOT)/zpr-visaservice/target/release/vs-admin" \
		"$(ZPR_ROOT)/zpr-visaservice/target/release/vsapikey" bin/

# zpr-dashboard is Go, not cargo — its own Makefile builds into its own bin/.
dashboard: check-zpr-root
	mkdir -p bin
	cd "$(ZPR_ROOT)/zpr-visaservice/zpr-dashboard" && $(MAKE) build
	cp "$(ZPR_ROOT)/zpr-visaservice/zpr-dashboard/bin/zpr-dashboard" bin/

compiler: check-zpr-root
	mkdir -p bin
	cd "$(ZPR_ROOT)/zpr-compiler" && cargo build --release
	cp "$(ZPR_ROOT)/zpr-compiler/target/release/zplc" \
		"$(ZPR_ROOT)/zpr-compiler/target/release/zpdump" bin/

clean:
	rm -rf bin
