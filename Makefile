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

# `-K` (prompt for the sudo password) is on by default, because before the very
# first apply there is no sudoers drop-in yet. Once `sudo_passwordless` has been
# applied, drop it - the prompt is then pure friction, and it does not work at
# all from a non-tty (getpass warns "Can not control echo on the terminal" and
# the run dies with "Missing sudo password"):
#
#     make diff ASKPASS=
ASKPASS ?= -K
ANSIBLE_ARGS := $(if $(LIMIT),--limit $(LIMIT),) $(if $(TAGS),--tags $(TAGS),) \
                $(if $(SKIP),--skip-tags $(SKIP),) $(EXTRA)

.DEFAULT_GOAL := help

# inventory.yml is gitignored - it holds your hostnames and addresses. Without
# this guard a fresh clone gets ansible's "provided hosts list is empty" warning
# and then "skipping: no hosts matched", which reads like a tag typo rather than
# a missing file.
.PHONY: inventory
inventory:
	@test -f inventory.yml || { \
	  echo "inventory.yml is missing - it is gitignored, so a fresh clone has none."; \
	  echo "Seed it and edit your hostnames and addresses:"; \
	  echo; echo "    cp inventory.example.yml inventory.yml"; echo; \
	  exit 1; }

.PHONY: help
help:  ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-14s\033[0m %s\n", $$1, $$2}'

# --- Checks that run anywhere (and in CI) ----------------------------------

.PHONY: check
check: lint syntax smoke render handlers optional-tags docs lockfile shellcheck  ## Every offline check (what CI runs)

.PHONY: deps
deps:  ## Install the pinned collections
	ansible-galaxy collection install -r requirements.yml

.PHONY: lint
lint:  ## ansible-lint at the production profile
	ansible-lint --nocolor

.PHONY: syntax
syntax: inventory  ## Parse the playbooks
	ansible-playbook site.yml --syntax-check
	ansible-playbook verify.yml --syntax-check
	ansible-playbook optional.yml --syntax-check
	ansible-playbook benchmark.yml --syntax-check

# --syntax-check does NOT load stdout callbacks, so it passes on a config that
# aborts every real run - exactly the bug that shipped once. Execute a trivial
# play so the whole config path is exercised for real.
.PHONY: smoke
smoke: inventory  ## Prove ansible.cfg actually loads and a play can run
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

# Tags on a dynamic include select the include, not the tasks inside it. Without
# `apply:`, `make optional TAGS=ray` includes the role, runs zero tasks and
# reports success. Nothing else offline sees it - --syntax-check passes and
# --list-tasks does not expand dynamic includes.
.PHONY: optional-tags
optional-tags:  ## Every optional include_role must push its tag onto the role's tasks
	@python3 tests/check_optional_tags.py

# A stale index is worse than no index - it denies the existence of a role or
# runbook, confidently. This checks coverage only, not prose quality.
.PHONY: docs
docs:  ## Directory indexes must list every role, runbook and vars file
	@python3 tests/check_docs.py

# The ML lockfile is one resolution and only means anything whole. Two ways it
# silently stops being that: regenerated without --index-strategy (the cu130
# index then shadows PyPI for torch's deps and you get 2022 versions), or a
# Dependabot security update bumps one pin - which cannot be turned off per
# manifest, so it will be attempted eventually.
.PHONY: lockfile
lockfile:  ## The ML lockfile must be a real resolution, not a hand-edit
	@python3 tests/check_lockfile.py

.PHONY: shellcheck
shellcheck:  ## Lint the shell scripts (skipped if shellcheck is absent)
	@if command -v shellcheck > /dev/null; then \
		files="bootstrap.sh $$(grep -rl '^#!.*bash' roles/*/files/ 2>/dev/null | sort || true)"; \
		shellcheck $$files && echo "shellcheck: clean ($$(echo $$files | wc -w) files)"; \
	else \
		echo "shellcheck: not installed locally - CI runs it"; \
	fi

# --- Targets that need the real hardware -----------------------------------

.PHONY: diff
diff: inventory  ## Dry run showing what would change (ASKPASS= once sudo is passwordless)
	ansible-playbook site.yml $(ASKPASS) --check --diff $(ANSIBLE_ARGS)

.PHONY: apply
apply: inventory  ## Provision. Run under tmux. (ASKPASS= once sudo is passwordless)
	ansible-playbook site.yml $(ASKPASS) $(ANSIBLE_ARGS)

.PHONY: verify
verify: inventory  ## Assert the node is in the expected state; fails loudly if not
	ansible-playbook verify.yml $(ANSIBLE_ARGS)

# Deliberately not part of `verify`. Verify is seconds, read-only and safe on a
# busy box; this loads the GPUs, the fabric and the disk for minutes.
.PHONY: bench
bench: inventory  ## Benchmark the cluster (needs: make optional TAGS=bench)
	ansible-playbook benchmark.yml $(ANSIBLE_ARGS)

.PHONY: models
models: inventory  ## Download the model sets (long; resumable)
	ansible-playbook site.yml $(ASKPASS) --tags models $(ANSIBLE_ARGS)

.PHONY: optional
optional: inventory  ## Install an opt-in component: make optional TAGS=ray|slurm|exporters|dashboards|node|bench
	@[ -n "$(TAGS)" ] || { echo "pick one: make optional TAGS=ray|slurm|exporters|dashboards|node|bench"; exit 1; }
	ansible-playbook optional.yml $(ASKPASS) --tags $(TAGS) $(if $(LIMIT),--limit $(LIMIT),) $(EXTRA)

# Resolve roles/ml/files/requirements-ml.in into a fully pinned .txt.
#
# MUST run on a GX10, not your laptop: the resolution is specific to aarch64
# and to the cu130 index that carries the only sm_121 torch wheels. Resolving
# it anywhere else produces a lockfile that installs the wrong torch.
#
# This only reads package metadata - it installs nothing. Commit the result;
# that file is what makes two boxes provisioned months apart identical.
.PHONY: lock
lock:  ## Re-resolve the ML lockfile (run ON a GX10; commit the result)
	@uname -m | grep -qx aarch64 || { echo "lock: must run on aarch64 - see the comment in the Makefile"; exit 1; }
#
# --index-strategy unsafe-best-match is LOAD-BEARING, not tuning. The cu130
# index is not torch-only: it carries frozen copies of torch's runtime deps,
# and as the priority index under uv's default `first-index` strategy it
# shadows PyPI for every one of them. Without this flag the same .in resolves
# certifi==2022.12.7, requests==2.28.1 and datasets==1.1.1 - a four-year-old CA
# bundle and a datasets that cannot work with transformers 5.x - because the
# resolver backtracks the whole stack down to what the shadowed pins allow, and
# says nothing. Version floors do not fix it; first-index refuses to fall
# through to PyPI at all.
#
# --emit-index-url copies the index directives into the .txt. Without them the
# lockfile is uninstallable, but it fails loudly (+cu130 does not exist on
# PyPI) rather than quietly resolving to the wrong wheels.
	uv pip compile roles/ml/files/requirements-ml.in \
		--output-file roles/ml/files/requirements-ml.txt \
		--python-version $(shell sed -n 's/^ml_python: *"\(.*\)"/\1/p' group_vars/all.yml) \
		--index-strategy unsafe-best-match \
		--emit-index-url
	@echo "lock: regenerated - review the diff before committing"

# The canonical Ansible test: a correct playbook changes nothing on a second
# run. NOTE it catches only one direction - a task that reports changed when it
# should not. A changed_when that NEVER fires makes this target pass.
.PHONY: idempotence
idempotence: inventory  ## Apply twice; the second run must report zero changes
	@echo "==> first run"
	@ansible-playbook site.yml $(ASKPASS) $(ANSIBLE_ARGS) > /dev/null
	@echo "==> second run (must be changed=0)"
	@ansible-playbook site.yml $(ASKPASS) $(ANSIBLE_ARGS) | tee .idem.log | tail -20
	@if grep -qE 'changed=[1-9]' .idem.log; then \
		echo; echo "IDEMPOTENCE FAILED - tasks reported changed on a no-op run."; \
		echo "Find them with: grep -B5 'changed:' .idem.log"; \
		exit 1; \
	else echo "idempotence: clean"; rm -f .idem.log; fi
