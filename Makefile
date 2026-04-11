SHELL := /bin/bash

.PHONY: dev build run test package

dev:
	bash ./scripts/dev.sh

build:
	swift build

run:
	swift run

test:
	swift test

package:
	bash ./scripts/package.sh
