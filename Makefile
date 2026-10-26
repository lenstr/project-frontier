.PHONY: build run test stress clean
build:
	./tools/build.sh
run: build
	./run.sh
test:
	./tools/test.sh
stress: build
	./run.sh --stress 200
clean:
	rm -rf build
