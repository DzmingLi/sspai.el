EMACS ?= emacs
EMACSFLAGS ?= --batch
ELISP_PATH ?=

BATCH = $(EMACS) $(EMACSFLAGS) -L . $(addprefix -L ,$(ELISP_PATH))

.PHONY: check test compile clean

check: compile test

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile sspai.el

test:
	$(BATCH) -l test/sspai-test.el -f ert-run-tests-batch-and-exit

clean:
	rm -f sspai.elc
