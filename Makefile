.PHONY: build run test stress format format-check clean
build:
	./tools/build.sh
run: build
	./run.sh
test:
	./tools/test.sh
stress: build
	./run.sh --stress 200
format:
	./tools/format.sh
format-check:
	./tools/format.sh --check
clean:
	rm -rf build
