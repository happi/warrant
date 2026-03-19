## Warrant Server — Development Makefile
## For build/push/deploy, use: server-infrastructure/k8s/apps/backlog-server/Makefile

.PHONY: compile shell clean test

compile:
	rebar3 compile

shell:
	rebar3 shell --apps backlog_server --config config/sys.config

clean:
	rebar3 clean

test:
	rebar3 eunit
