BUILDDIR=build
ZPRBUILDDIR=../src/build
BASDB=db
USE_DOCKER ?= 0

BAS=$(ZPRBUILDDIR)/bin/bas

ifeq ($(USE_DOCKER),1)
    _CONFIGDIR := $(abspath $(CURDIR))
    _BAS_BIN   := $(abspath $(ZPRBUILDDIR)/bin/bas)
    BAS_RUN = docker run --rm -v "$(_CONFIGDIR):/config" -v "$(_BAS_BIN):/usr/local/bin/bas" -w /config zpr/dev-env:latest bas
else
    BAS_RUN = $(BAS)
endif


.PHONY: info
info:
	@echo
	@echo "  make creds - rebuild the entire credential set for the demo"
	@echo "  make basdb - create the bas db entries and the bas keys"
	@echo "  make clean - wipe the creds build and bas directories"
	@echo


.PHONY: creds
creds:
	python3 ./tools/generate_artifacts.py --builddir $(BUILDDIR) --zprbuilddir $(ZPRBUILDDIR)


.PHONY: basdb
basdb:
	rm -rf $(BASDB)
	$(BAS_RUN) create admin.zpr.org
	$(BAS_RUN) add-attribute admin.zpr.org bas_id:1000
	$(BAS_RUN) add-attribute admin.zpr.org color:blue
	$(BAS_RUN) create cli.zpr.org
	$(BAS_RUN) add-attribute cli.zpr.org bas_id:1001
	$(BAS_RUN) add-attribute cli.zpr.org color:green
	$(BAS_RUN) create web.zpr.org
	$(BAS_RUN) add-attribute web.zpr.org bas_id:1234
	$(BAS_RUN) add-attribute web.zpr.org color:purple
	$(BAS_RUN) add-attribute web.zpr.org content:green
	@mkdir -p $(BUILDDIR)/keys
	openssl rand -out $(BUILDDIR)/keys/bas-token-hmac.key 48
	chmod 600 $(BUILDDIR)/keys/bas-token-hmac.key
	cp $(BASDB)/cn.admin.zpr.org/private.pem $(BUILDDIR)/keys/adapter-admin-bas.key
	cp $(BASDB)/cn.cli.zpr.org/private.pem $(BUILDDIR)/keys/adapter-cli-bas.key
	cp $(BASDB)/cn.web.zpr.org/private.pem $(BUILDDIR)/keys/adapter-web-bas.key


.PHONY: clean
clean:
	rm -rf $(BUILDDIR)
	rm -rf $(BASDB)


.DEFAULT_GOAL := info

