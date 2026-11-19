# rebar3_jellyfish_plugin developer convenience targets.
#
# Thin wrappers over rebar3, for discoverability. Run these in a shell whose
# toolchain matches .tool-versions.

.DEFAULT_GOAL := help
.PHONY: help clean compile test xref integration check release

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

clean: ## Remove build artifacts
	rebar3 clean
	rm -rf _build

compile: ## Compile the plugin
	rebar3 compile

test: ## Run the unit test suite
	rebar3 eunit

xref: ## Run cross reference analysis
	rebar3 xref

integration: ## Build real single-app and umbrella releases through the plugin and inspect them
	bash test/integration/run.sh

check: compile test xref integration ## Run all pre-PR checks

release: check ## Bump the version, tag, push, publish to Hex, and create a GitHub release - runs check first
	rebar3 hex cut
	git push --tags
	gh release create "v$$(sed -n 's/.*{vsn, "\(.*\)"}.*/\1/p' src/rebar3_jellyfish_plugin.app.src)" --generate-notes
