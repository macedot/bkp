# bkp — standalone Odin backup tool
CC      ?= cc
CFLAGS  ?= -O2 -fPIC -Ivendor
ODIN    ?= odin
BUILD   := build
LIB     := $(BUILD)/libbkpminiz.a
OBJS    := $(BUILD)/miniz.o $(BUILD)/bkp_miniz_wrap.o

# Output binary name (override with OUT=bkp.exe on Windows)
OUT     ?= bkp

.PHONY: all clean test

all: $(OUT)

$(BUILD):
	mkdir -p $(BUILD)

$(BUILD)/miniz.o: vendor/miniz.c vendor/miniz.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ vendor/miniz.c

$(BUILD)/bkp_miniz_wrap.o: vendor/bkp_miniz_wrap.c vendor/miniz.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ vendor/bkp_miniz_wrap.c

$(LIB): $(OBJS)
	ar rcs $@ $(OBJS)

$(OUT): $(LIB) src/*.odin
	$(ODIN) build src -out:$(OUT) -o:speed

clean:
	rm -rf $(BUILD) bkp bkp.exe

# Quick functional smoke test (Unix)
test: $(OUT)
	@set -e; \
	TMP=$$(mktemp -d); \
	mkdir -p "$$TMP/dir/sub"; \
	echo hello > "$$TMP/a.txt"; \
	echo world > "$$TMP/dir/sub/b.txt"; \
	cp "$$TMP/a.txt" "$$TMP/dir/"; \
	OUT_TXT=$$(cd "$$TMP" && "$(CURDIR)/$(OUT)" -j 2 -c 2 a.txt dir 2>"$$TMP/err"); \
	echo "$$OUT_TXT"; \
	test -z "$$(cat "$$TMP/err")" || (echo "STDERR:" && cat "$$TMP/err" && exit 1); \
	echo "$$OUT_TXT" | grep -q 'a.txt -> a.txt.'; \
	echo "$$OUT_TXT" | grep -q 'dir -> dir.'; \
	ZIP=$$(ls "$$TMP"/dir.*.zip); \
	unzip -t "$$ZIP"; \
	diff -u "$$TMP/a.txt" "$$TMP"/a.txt.*; \
	echo "OK"; \
	rm -rf "$$TMP"
