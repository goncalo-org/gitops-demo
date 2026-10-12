.PHONY: up down lint test

up:
	./scripts/bootstrap.sh

down:
	kind delete cluster --name dev
	kind delete cluster --name prod

lint:
	./scripts/lint.sh

test:
	./scripts/smoke-test.sh
