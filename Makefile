EMACS ?= emacs
STRAIGHT_BUILD ?= $(HOME)/thomas-emacs/.local/straight/build-31.1
ELPA_LOAD_PATH ?= -L $(STRAIGHT_BUILD)/etaf -L $(STRAIGHT_BUILD)/etaf-ui \
                  -L $(STRAIGHT_BUILD)/ebox -L $(STRAIGHT_BUILD)/ecss
LOAD_PATH = -L . -L lisp $(ELPA_LOAD_PATH)
EL_FILES   = $(strip $(wildcard *.el) $(wildcard lisp/*.el))
TEST_FILES = $(strip $(wildcard test/*-tests.el))
PARENS_FILES = $(strip $(EL_FILES) $(TEST_FILES))

.PHONY: check check-parens compile test test-avy clean

check: check-parens compile test

check-parens:
	@if [ -z "$(PARENS_FILES)" ]; then echo "check-parens: 无 .el 文件，跳过"; exit 0; fi; \
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq load-prefer-newer t)' \
	  --eval '(let ((fail nil) (files (cdr (member "--" command-line-args)))) (dolist (f files) (with-temp-buffer (insert-file-contents f) (emacs-lisp-mode) (condition-case err (check-parens) (error (setq fail t) (message "check-parens FAIL %s: %s" f err))))) (if fail (kill-emacs 1) (message "check-parens OK (%d files)" (length files))))' -- $(PARENS_FILES)

compile:
	@if [ -z "$(EL_FILES)" ]; then echo "compile: 无 .el 文件，跳过"; exit 0; fi; \
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq load-prefer-newer t)' \
	  --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(EL_FILES)

test:
	@if [ -z "$(TEST_FILES)" ]; then echo "test: 无测试文件，0 项通过"; exit 0; fi; \
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval '(setq load-prefer-newer t)' \
	  -l ert $(patsubst %,-l %, $(TEST_FILES)) \
	  --eval '(ert-run-tests-batch-and-exit t)'

test-avy:
	@if [ -z "$(TEST_FILES)" ]; then echo "test-avy: 无测试文件，0 项通过"; exit 0; fi; \
	$(EMACS) -Q --batch $(LOAD_PATH) -L $(STRAIGHT_BUILD)/avy \
	  --eval '(setq load-prefer-newer t)' \
	  -l ert $(patsubst %,-l %, $(TEST_FILES)) \
	  --eval '(ert-run-tests-batch-and-exit t)'

clean:
	rm -f $(EL_FILES:.el=.elc)
