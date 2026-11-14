EMACS ?= emacs
SRCS = muesli-core.el muesli-db.el muesli-capture.el muesli-record.el \
       muesli-stt.el muesli-diarize.el muesli-summary.el muesli.el muesli-relay.el

.PHONY: all compile test checkdoc clean

all: compile checkdoc test

compile:
	$(EMACS) -Q --batch -L . --eval '(setq byte-compile-error-on-warn t)' -f batch-byte-compile $(SRCS)

test:
	$(EMACS) -Q --batch -L . -L test --eval "(setq load-prefer-newer t)" -l test/muesli-test.el -l test/muesli-relay-test.el -f ert-run-tests-batch-and-exit

checkdoc:
	$(EMACS) -Q --batch -L . --eval '(progn (require (quote checkdoc)) (setq checkdoc-diagnostic-buffer "*warn*") (dolist (f (list $(foreach s,$(SRCS),"$(s)"))) (checkdoc-file f)))'

clean:
	rm -f *.elc test/*.elc
