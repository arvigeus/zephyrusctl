PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
SYSTEMD := /etc/systemd/system
STATE := /var/lib/zephyrusctl

.PHONY: install uninstall check

install:
	@if [ "$$(id -u)" -ne 0 ]; then echo "ERROR: run as root (sudo make install)" >&2; exit 1; fi
	install -m 0755 zephyrusctl.sh $(BINDIR)/zephyrusctl
	install -d -m 0755 $(STATE)
	install -m 0644 systemd/zephyrusctl.service $(SYSTEMD)/zephyrusctl.service
	install -m 0644 systemd/zephyrusctl.timer   $(SYSTEMD)/zephyrusctl.timer
	systemctl daemon-reload

uninstall:
	@if [ "$$(id -u)" -ne 0 ]; then echo "ERROR: run as root (sudo make uninstall)" >&2; exit 1; fi
	-systemctl stop zephyrusctl.timer 2>/dev/null
	rm -f $(BINDIR)/zephyrusctl
	rm -f $(SYSTEMD)/zephyrusctl.service
	rm -f $(SYSTEMD)/zephyrusctl.timer
	rm -rf $(STATE)
	systemctl daemon-reload

check:
	shellcheck zephyrusctl.sh
	shfmt -w zephyrusctl.sh
