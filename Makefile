SHA1 := $(shell git rev-parse HEAD)
GIT_BRANCH:= $(shell git rev-parse --abbrev-ref HEAD)

sha1:
	docker build -t "zarakailloux/vauban:${SHA1}" --build-arg "VAUBAN_SHA1=${SHA1}" --build-arg "BRANCH=${GIT_BRANCH}" .

latest:
	docker build -t "zarakailloux/vauban:latest" --build-arg "VAUBAN_SHA1=${SHA1}" --build-arg "VAUBAN_BRANCH=${GIT_BRANCH}" .

all: sha1 latest
	# FIXME make it configurable
