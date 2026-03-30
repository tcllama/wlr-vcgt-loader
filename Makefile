PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

PKG_CONFIG ?= pkg-config
WAYLAND_SCANNER ?= $(shell $(PKG_CONFIG) --variable=wayland_scanner wayland-scanner 2>/dev/null || echo wayland-scanner)

CPPFLAGS += -I.
CFLAGS += -std=c11 -O2 -Wall -Wextra
CFLAGS += $(shell $(PKG_CONFIG) --cflags wayland-client lcms2)
TEST_CFLAGS += $(shell $(PKG_CONFIG) --cflags cmocka 2>/dev/null)

LDLIBS += $(shell $(PKG_CONFIG) --libs wayland-client lcms2) -lm
TEST_LDLIBS += $(shell $(PKG_CONFIG) --libs cmocka 2>/dev/null)

PROTO_XML = protocol/wlr-gamma-control-unstable-v1.xml
PROTO_C   = wlr-gamma-control-unstable-v1-protocol.c
PROTO_H   = wlr-gamma-control-unstable-v1-client-protocol.h

OBJS = main.o $(PROTO_C:.c=.o)
TEST_OBJS = tests/test_main.o main-test.o $(PROTO_C:.c=.o)
TEST_BIN = tests/test-wlr-vcgt-loader

all: wlr-vcgt-loader

test: wlr-vcgt-loader $(TEST_BIN)
	./$(TEST_BIN)

$(PROTO_C): $(PROTO_XML)
	$(WAYLAND_SCANNER) private-code $< $@

$(PROTO_H): $(PROTO_XML)
	$(WAYLAND_SCANNER) client-header $< $@

$(PROTO_C:.c=.o): $(PROTO_C) $(PROTO_H)

main.o: main.c $(PROTO_H) wlr_vcgt_loader_internal.h

main-test.o: main.c $(PROTO_H) wlr_vcgt_loader_internal.h
	$(CC) $(CPPFLAGS) $(CFLAGS) -DWLR_VCGT_LOADER_TESTING -Wno-unused-function -Wno-unused-const-variable -c $< -o $@

tests/test_main.o: tests/test_main.c $(PROTO_H) wlr_vcgt_loader_internal.h
	$(CC) $(CPPFLAGS) $(CFLAGS) $(TEST_CFLAGS) -c $< -o $@

$(TEST_BIN): $(TEST_OBJS)
	$(CC) -o $@ $(TEST_OBJS) $(LDFLAGS) $(LDLIBS) $(TEST_LDLIBS)

wlr-vcgt-loader: $(OBJS)
	$(CC) -o $@ $(OBJS) $(LDFLAGS) $(LDLIBS)

install: wlr-vcgt-loader
	install -Dm755 wlr-vcgt-loader $(DESTDIR)$(BINDIR)/wlr-vcgt-loader

uninstall:
	rm -f $(DESTDIR)$(BINDIR)/wlr-vcgt-loader

clean:
	rm -f wlr-vcgt-loader $(TEST_BIN) $(OBJS) main-test.o tests/test_main.o $(PROTO_C) $(PROTO_H)

.PHONY: all test install uninstall clean
