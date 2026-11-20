// The only place the Resources page and the slash popover touch the app's MainController.

import AppKit

enum ResourcesPageFactory {
    /// Called from MainController (main thread, not annotated), hence assumeIsolated.
    static func make(controller c: MainController) -> ResourcesPage {
        MainActor.assumeIsolated {
            let page = ResourcesPage(service: c.resourcesService)
            page.openTerminal = { [unowned c] name, command in
                c.showPage(nil)
                c.store.openShell(cwd: c.store.home, name: name, typing: command)
            }
            page.report = { [unowned c] text in
                // Today's page shows an alert; a sheet-less line in the log keeps the debug runs unblocked.
                if ProcessInfo.processInfo.environment["MUYA_DEBUG_SOCKET"] != nil { print("resources: \(text)"); return }
                let a = NSAlert(); a.messageText = text; a.addButton(withTitle: "OK"); a.beginSheetModal(for: c.window)
            }
            return page
        }
    }
}

extension MainController {
    func wireSlash() {
        MainActor.assumeIsolated {
            slashPopover.onPick = { [weak self] name in self?.store.sendText("/\(name) ") }
            slashPopover.onClose = { [weak self] in self?.restoreFocus() }
        }
    }

    /// ⌘/: the commands of the agent in the selected terminal (Claude unless the terminal says otherwise),
    /// built-ins at once, project / user commands and skills when the daemon answers.
    @objc func toggleSlash() {
        MainActor.assumeIsolated {
            if slashPopover.isOpen { slashPopover.close(); return }
            closeViewer()
            let agent = "claude"
            slashPopover.open(agent: agent, loading: true)
            resourcesService.slashDisk(agent: agent, cwd: store.selected?.cwd) { [weak self] disk in
                guard let self, self.slashPopover.isOpen else { return }
                self.slashPopover.update(agent: agent, disk: disk)
            }
        }
    }
}
