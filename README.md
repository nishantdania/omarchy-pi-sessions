# Omarchy Pi Sessions

An Omarchy bar widget for monitoring live [Pi](https://pi.dev) coding sessions.

## Features

- Running and waiting session sections
- Short task titles generated with `openai-codex/gpt-5.6-luna` at low reasoning
- Click a session to focus its exact terminal
- Tmux pane selection and detached-session reattachment
- Clickable, deduplicated completion notifications
- Automatic removal when Pi exits
- No generated Pi session names

## Install

Review the repository before installing. Both the Omarchy plugin and Pi extension run with your user permissions.

```bash
omarchy plugin add https://github.com/nishantdania/omarchy-pi-sessions.git --enable
pi install https://github.com/nishantdania/omarchy-pi-sessions.git
```

Reload an already-running Pi instance with `/reload`. New Pi instances load the extension automatically.

## Update

```bash
omarchy plugin update nishant.pi-sessions
pi update --extensions
```

## Remove

```bash
omarchy plugin disable nishant.pi-sessions
omarchy plugin remove nishant.pi-sessions --yes
pi remove https://github.com/nishantdania/omarchy-pi-sessions.git
```

## How it works

The Pi extension writes one live record per process under:

```text
~/.local/state/pi/session-tracker/
```

The Omarchy widget polls those records through the bundled helper. The helper resolves Hyprland windows, tmux clients, windows, and panes when activating a session.

For unnamed sessions, the extension sends up to the first 4,000 characters of the expanded first prompt to `openai-codex/gpt-5.6-luna`. The generated title is stored only in the tracker record and is not assigned as the Pi session name. If Luna or authentication is unavailable, a local fallback title is used.

Notification deduplication state is stored under:

```text
~/.local/state/pi/session-tracker-notifications/
```

## Requirements

- Omarchy with the Quickshell plugin system
- Pi with extension package support
- Python 3
- `tmux` for tmux integration

## Development

```bash
omarchy plugin validate .
python -m py_compile bin/omarchy-pi-session
```

The plugin hot-reloads when developed directly under `~/.config/omarchy/plugins/`.

## License

MIT
