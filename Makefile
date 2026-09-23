APP_NAME := Hinge
APP := build/Build/Products/Release/$(APP_NAME).app
BIN := $(APP)/Contents/MacOS/$(APP_NAME)

.PHONY: all project build probe status run clean install test check

all: build

project:
	xcodegen generate

build:
	sh scripts/build.sh --no-install

probe: build
	"$(BIN)" --probe

status:
	"$(BIN)" --status

run: build
	open "$(APP)"

install:
	sh scripts/build.sh

test:
	sh scripts/test.sh

check: test
	sh scripts/build.sh --no-install

clean:
	rm -rf build Hinge.xcodeproj Hinge.app
