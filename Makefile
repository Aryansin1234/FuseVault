CC      = gcc
CFLAGS  = -Wall -Wextra -Wpedantic $(shell pkg-config fuse --cflags)
LDFLAGS = $(shell pkg-config fuse --libs) -lssl -lcrypto
TARGET  = myfs
SRC     = src/myfs.c

.PHONY: all debug clean install uninstall test lint format help

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $(TARGET)

debug: CFLAGS  += -g -DDEBUG -fsanitize=address,undefined
debug: LDFLAGS += -fsanitize=address,undefined
debug: $(SRC)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $(TARGET)

clean:
	rm -f $(TARGET) *.o

INSTALL_BIN = /usr/local/bin

install: $(TARGET)
	install -m 755 $(TARGET) $(INSTALL_BIN)/myfs
	install -m 755 scripts/vault.sh $(INSTALL_BIN)/vault
	install -m 755 scripts/fusevault_ui.sh $(INSTALL_BIN)/fusevault
	@echo "Installed myfs, vault, and fusevault to $(INSTALL_BIN)"
	@echo "  vault      — CLI backend (mount, unmount, keygen, log, ...)"
	@echo "  fusevault  — Interactive TUI (powered by gum)"

uninstall:
	rm -f $(INSTALL_BIN)/myfs $(INSTALL_BIN)/vault $(INSTALL_BIN)/fusevault
	@echo "Uninstalled myfs, vault, and fusevault"

test: all
	@echo "=== FuseVault Self-Test ==="
	@./scripts/vault.sh keygen
	@./scripts/vault.sh mount
	@sleep 1
	@fname="selftest_$$$$.txt"; \
	  echo "FUSEVAULT_TEST_CONTENT_$$$$" > "mount/$$fname"; \
	  content=$$(cat "mount/$$fname"); \
	  if echo "$$content" | grep -q "FUSEVAULT_TEST_CONTENT"; then \
	    echo "READ/WRITE: PASS"; \
	  else \
	    echo "READ/WRITE: FAIL (got: $$content)"; exit 1; \
	  fi; \
	  rm -f "mount/$$fname"
	@./scripts/vault.sh unmount
	@echo "=== Self-test PASSED ==="

lint:
	cppcheck --enable=all --suppress=missingIncludeSystem --suppress=checkersReport src/myfs.c

format:
	clang-format -i -style=GNU src/myfs.c

help:
	@echo "FuseVault build targets:"
	@echo "  all       - Build myfs binary (default)"
	@echo "  debug     - Build with debug symbols and AddressSanitizer"
	@echo "  clean     - Remove build artifacts"
	@echo "  install   - Install myfs, vault, and fusevault to $(INSTALL_BIN)"
	@echo "  uninstall - Remove installed files"
	@echo "  test      - Run mount/write/read/unmount self-test"
	@echo "  lint      - Run cppcheck on src/myfs.c"
	@echo "  format    - Run clang-format on src/myfs.c"
	@echo ""
	@echo "After install, use:"
	@echo "  vault      <command>   CLI backend"
	@echo "  fusevault              Interactive TUI"
