# One entry point for everything. `make` on its own lists the targets.
#
# The split that matters: `check` targets run anywhere and are what CI runs.
# `apply`, `verify` and `idempotence` need the real hardware and sudo, so they
# are never in CI - the GB10, the CUDA driver and the ConnectX-7 cannot be
# faked in a container.

# -o pipefail so a failing command in a pipeline fails the recipe. Without it
# `cmd | tee | tail` reports tail's status and a dead run looks successful.
SHELL := /bin/bash -o pipefail
export PATH := $(HOME)/.local/bin:$(PATH)

LIMIT ?=
TAGS  ?=
SKIP  ?=
# Passthrough for anything else. Note you CANNOT write `make apply -e foo=bar`
# - make eats -e as --environment-overrides and the variable never reaches
# ansible. Use: make apply EXTRA='-e allow_apt_upgrade=true'
EXTRA ?=
ANSIBLE_ARGS := $(if $(LIMIT),--limit $(LIMIT),) $(if $(TAGS),--tags $(TAGS),) \
                $(if $(SKIP),--skip-tags $(SKIP),) $(EXTRA)

.DEFAULT_GOAL := help

.PHONY: help
help:  ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

# --- Checks that run anywhere (and in CI) ----------------------------------

.PHONY: check
check: lint syntax smoke render handlers docs shellcheck  ## Every offline check (what CI runs)

.PHONY: deps
deps:  ## Install the pinned collections
	ansible-galaxy collection install -r requirements.yml

.PHONY: lint
lint:  ## ansible-lint at the production profile
	ansible-lint --nocolor

.PHONY: syntax
syntax:  ## Parse the playbooks
	ansible-playbook site.yml --syntax-check
	ansible-playbook verify.yml --syntax-check

# --syntax-check does NOT load stdout callbacks, so it passes on a config that
# aborts every real run - exactly the bug that shipped once. Execute a trivial
# play so the whole config path is exercised for real.
.PHONY: smoke
smoke:  ## Prove ansible.cfg actually loads and a play can run
	@printf '%s\n' \
		'- hosts: localhost' \
		'  connection: local' \
		'  gather_facts: false' \
		'  tasks: [{ ansible.builtin.debug: { msg: ok } }]' > .smoke.yml
	@ansible-playbook .smoke.yml > /dev/null && echo "smoke: ansible.cfg loads, play runs" \
		|| { echo "smoke: FAILED - ansible.cfg is broken"; ansible-playbook .smoke.yml; rm -f .smoke.yml; exit 1; }
	@rm -f .smoke.yml

# Templates are the other thing lint cannot see: an undefined variable or a bad
# filter only surfaces when it renders.
.PHONY: render
render:  ## Render every template against real facts
	@d=$$(mktemp -d); trap 'rm -rf $$d' EXIT; \
	ansible-playbook tests/render.yml -e out=$$d > /dev/null \
		&& echo "render: all templates render" \
		|| { echo "render: FAILED"; ansible-playbook tests/render.yml -e out=$$d; exit 1; }

# Ansible only errors on an unknown handler when the notifying task actually
# reports changed - so a typo'd notify stays invisible on an already-provisioned
# box and detonates on a first-time provision, the run you least want to fail.
# Nothing else offline can catch it.
.PHONY: handlers
handlers:  ## Every notify: must name a handler that exists in the same role
	@python3 tests/check_handlers.py

# A stale index is worse than no index - it denies the existence of a role or
# runbook, confidently. This checks coverage only, not prose quality.
.PHONY: docs
docs:  ## Directory indexes must list every role, runbook and vars file
	@python3 tests/check_docs.py

.PHONY: shellcheck
shellcheck:  ## Lint the shell scripts (skipped if shellcheck is absent)
	@if command -v shellcheck > /dev/null; then \
		shellcheck bootstrap.sh && echo "shellcheck: clean"; \
	else \
		echo "shellcheck: not installed locally - CI runs it"; \
	fi

# --- Targets that need the real hardware -----------------------------------

.PHONY: diff
diff:  ## Dry run showing what would change (-K prompts for sudo)
	ansible-playbook site.yml -K --check --diff $(ANSIBLE_ARGS)

.PHONY: apply
apply:  ## Provision (-K prompts for sudo). Run under tmux.
	ansible-playbook site.yml -K $(ANSIBLE_ARGS)

.PHONY: verify
verify:  ## Assert the node is in the expected state; fails loudly if not
	ansible-playbook verify.yml $(ANSIBLE_ARGS)

.PHONY: models
models:  ## Download the model sets (long; resumable)
	ansible-playbook site.yml -K --tags models $(ANSIBLE_ARGS)

.PHONY: orchestrator
orchestrator:  ## Install ray or slurm: make orchestrator TAGS=ray
	@[ -n "$(TAGS)" ] || { echo "pick one: make orchestrator TAGS=ray|slurm"; exit 1; }
	ansible-playbook orchestrator.yml -K --tags $(TAGS) $(if $(LIMIT),--limit $(LIMIT),) $(EXTRA)

# The canonical Ansible test: a correct playbook changes nothing on a second
# run. NOTE it catches only one direction - a task that reports changed when it
# should not. A changed_when that NEVER fires makes this target pass.
.PHONY: idempotence
idempotence:  ## Apply twice; the second run must report zero changes
	@echo "==> first run"
	@ansible-playbook site.yml -K $(ANSIBLE_ARGS) > /dev/null
	@echo "==> second run (must be changed=0)"
	@ansible-playbook site.yml -K $(ANSIBLE_ARGS) | tee .idem.log | tail -20
	@if grep -qE 'changed=[1-9]' .idem.log; then \
		echo; echo "IDEMPOTENCE FAILED - tasks reported changed on a no-op run."; \
		echo "Find them with: grep -B5 'changed:' .idem.log"; \
		exit 1; \
	else echo "idempotence: clean"; rm -f .idem.log; fi
