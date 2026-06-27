CC = gcc
CFLAGS = -O2 -Wall -Wextra -pthread
SRC = src/main.c src/config.c src/sync.c src/status.c src/metrics.c
BIN = /usr/local/sbin/ezmirord

.PHONY: all build install clean setup python-install

all: build

build: $(SRC)
	$(CC) $(CFLAGS) -o $(BIN) $(SRC)

install: build
	cp python/setup.py /usr/local/bin/ezmirror-setup
	cp python/manage.py /usr/local/bin/ezmirror-manage-py
	chmod +x /usr/local/bin/ezmirror-setup /usr/local/bin/ezmirror-manage-py
	cp templates/* /var/www/html/.templates/ 2>/dev/null || true

daemon: build
	cp $(BIN) /usr/local/sbin/ezmirord
	chmod +x /usr/local/sbin/ezmirord
	cp systemd/ezmirord.service /etc/systemd/system/ 2>/dev/null || true
	systemctl daemon-reload

setup:
	python3 python/setup.py

clean:
	rm -f $(BIN)
