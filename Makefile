EMACS ?= emacs
EMACSFLAGS ?= --batch
ELISP_PATH ?=

BATCH = $(EMACS) $(EMACSFLAGS) -L . $(addprefix -L ,$(ELISP_PATH))

.PHONY: check compile clean

check: compile

compile:
	$(BATCH) --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile sspai.el

clean:
	rm -f sspai.elc
