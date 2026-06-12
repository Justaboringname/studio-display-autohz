PREFIX := $(HOME)/.local/bin
BIN := studio-display-autohz
PLIST := com.justaboringname.studio-display-autohz.plist
AGENT_DIR := $(HOME)/Library/LaunchAgents

$(BIN): autohz.swift
	swiftc -O -o $(BIN) autohz.swift

install: $(BIN)
	mkdir -p $(PREFIX)
	cp $(BIN) $(PREFIX)/$(BIN)
	sed "s|__BIN__|$(PREFIX)/$(BIN)|" $(PLIST).template > $(AGENT_DIR)/$(PLIST)
	launchctl bootout gui/$$(id -u)/com.justaboringname.studio-display-autohz 2>/dev/null || true
	sleep 1
	launchctl bootstrap gui/$$(id -u) $(AGENT_DIR)/$(PLIST) || \
		{ sleep 2; launchctl bootstrap gui/$$(id -u) $(AGENT_DIR)/$(PLIST); }
	@echo "installed + agent loaded"

uninstall:
	launchctl bootout gui/$$(id -u)/com.justaboringname.studio-display-autohz 2>/dev/null || true
	rm -f $(AGENT_DIR)/$(PLIST) $(PREFIX)/$(BIN)
	@echo "uninstalled"

clean:
	rm -f $(BIN)

.PHONY: install uninstall clean
