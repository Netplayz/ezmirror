CC = gcc
CFLAGS = -O2 -Wall -Wextra -pthread
SRC = src/main.c src/config.c src/sync.c src/status.c src/metrics.c
BIN = ezmirord
PREFIX = /usr/local

.PHONY: all build install daemon setup clean

all: build

build: $(SRC)
	$(CC) $(CFLAGS) -o $(BIN) $(SRC)

install: build
	install -m 755 $(BIN) $(PREFIX)/sbin/ezmirord
	install -m 755 python/setup.py $(PREFIX)/bin/ezmirror-setup
	install -m 755 python/manage.py $(PREFIX)/bin/ezmirror-manage-py
	cp templates/* /var/www/html/.templates/ 2>/dev/null || true

daemon: install
	cp systemd/ezmirord.service /etc/systemd/system/ 2>/dev/null || true
	systemctl daemon-reload

setup:
	python3 python/setup.py

clean:
	rm -f $(BIN)
