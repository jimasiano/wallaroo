# include root makefile
ifndef ROOT_MAKEFILE_MK
include ../../../Makefile
endif

# prevent rules from being evaluated/included multiple times
ifndef $(abspath $(lastword $(MAKEFILE_LIST)))_MK
$(abspath $(lastword $(MAKEFILE_LIST)))_MK := 1


# The following are control variables that determine what logic from `rules.mk` is enabled

# `true`/`false` to enable/disable the actual unit test command so it can be overridden (the targets are still created)
# applies to both the pony and elixir test targets
$(abspath $(lastword $(MAKEFILE_LIST)))_UNIT_TEST_COMMAND := false

# `true`/`false` to enable/disable generate pony related targets (build/test/clean) for pony sources in this directory
# otherwise targets only get created if there are pony sources (*.pony) in this directory.
$(abspath $(lastword $(MAKEFILE_LIST)))_PONY_TARGET := false

# `true`/`false` to enable/disable generate final file build target using ponyc command for the pony build target so
# it can be overridden manually
$(abspath $(lastword $(MAKEFILE_LIST)))_PONYC_TARGET := false

# `true`/`false` to enable/disable generate exs related targets (build/test/clean) for elixir sources in this directory
# otherwise targets only get created if there are elixir sources (*.exs) in this directory.
$(abspath $(lastword $(MAKEFILE_LIST)))_EXS_TARGET := false

# `true`/`false` to enable/disable generate docker related targets (build/push) for a Dockerfile in this directory
# otherwise targets only get created if there is a Dockerfile in this directory
$(abspath $(lastword $(MAKEFILE_LIST)))_DOCKER_TARGET := false

# `true`/`false` to enable/disable recursing into Makefiles of subdirectories if they exist
# (and by recursion every makefile in the tree that is referenced)
$(abspath $(lastword $(MAKEFILE_LIST)))_RECURSE_SUBMAKEFILES := false

WORD_COUNT_GO_PATH := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
GO_PONY_LIB := $(wallaroo_path)/go_api/go
WORD_COUNT_GOPATH := $(WORD_COUNT_GO_PATH)/go:$(GO_PONY_LIB)

# standard rules generation makefile
include $(rules_mk_path)

build-examples-go-word_count: word_count_go_build
unit-tests-examples-go-word_count: build-examples-go-word_count
integration-tests-examples-go-word_count: build-examples-go-word_count
integration-tests-examples-go-word_count: word_count_go_test
clean-examples-go-word_count: word_count_go_clean

word_count_go_build: $(WORD_COUNT_GO_PATH)/word_count

word_count_go_clean:
	$(QUIET)rm -rf $(WORD_COUNT_GO_PATH)/lib $(WORD_COUNT_GO_PATH)/.deps $(WORD_COUNT_GO_PATH)/word_count $(WORD_COUNT_GO_PATH)/word_count.d

-include $(WORD_COUNT_GO_PATH)/word_count.d
$(WORD_COUNT_GO_PATH)/word_count: $(WORD_COUNT_GO_PATH)/lib/libwallaroo.a
	$(call PONYC,$(abspath $(WORD_COUNT_GO_PATH:%/=%)))

$(WORD_COUNT_GO_PATH)/lib/libwallaroo.a: $(WORD_COUNT_GO_PATH)/go/src/word_count/word_count.go
	$(QUIET)export GOPATH=$(WORD_COUNT_GOPATH) && go build -buildmode=c-archive -o $(WORD_COUNT_GO_PATH)lib/libwallaroo.a word_count

word_count_go_test:
	cd $(WORD_COUNT_GO_PATH) && \
	integration_test --newline-file-sender count_this.txt \
		--validation-cmd 'python _test/validate.py --expected _expected.json --output' \
		--log-level error \
		--batch-size 1 \
		--output 'received.txt' \
		--command './word_count' \
		--sink-mode newlines \
		--sink-expect 482
	cd $(WORD_COUNT_GO_PATH) && \
	integration_test --newline-file-sender count_this.txt \
		--validation-cmd 'python _test/validate.py --expected _expected.json --output' \
		--log-level error \
		--batch-size 1 \
		--output 'received.txt' \
		--command './word_count' \
		--sink-mode newlines \
		--sink-expect 482 \
		--workers 2
	cd $(WORD_COUNT_GO_PATH) && \
	integration_test --newline-file-sender count_this.txt \
		--validation-cmd 'python _test/validate.py --expected _expected.json --output' \
		--log-level error \
		--batch-size 1 \
		--output 'received.txt' \
		--command './word_count' \
		--sink-mode newlines \
		--sink-expect 482 \
		--workers 3

# end of prevent rules from being evaluated/included multiple times
endif
