# Background services

Enable the services plugin when a local program needs to keep running between Manager jobs.

```sh
manager plugin enable services
mkdir -p ~/.config/manager/services
```

Put one executable `NAME.sh` in `~/.config/manager/services` for each service. Each script accepts two commands.

- `ensure-daemon` checks the service and starts it if needed. Return when startup finishes. Make duplicate calls safe, including concurrent calls from two Manager invocations.
- `status` prints service health and exits nonzero when the service needs attention.

For example, a service already installed under a Linux user systemd instance can use this adapter.

```sh
#!/bin/sh
case "$1" in
  ensure-daemon) exec systemctl --user start notes-indexer.service ;;
  status) exec systemctl --user is-active notes-indexer.service ;;
  *) exit 2 ;;
esac
```

`manager start`, `manager watch`, and `manager recover` run the enabled services' startup checks. `manager status` prints their status. Schedule `manager watch` in your existing scheduler for periodic checks. `MANAGER_SERVICE_DIR` selects a different adapter directory. Each adapter owns its service's lifecycle, operating-system integration, and any recovery specific to that program.
