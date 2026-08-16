# chrome-arch-installer

Installs Google Chrome Stable locally on Arch or CachyOS without AUR and
without root privileges.

The installer extracts the official Google `.deb` into `~/Apps/google-chrome`,
installs the user launcher and registers the adapted desktop entry in
`~/.local/share/applications`.

## Install

Download and install the current stable package:

```bash
./install.sh
```

Install a package that is already downloaded:

```bash
./install.sh --deb ~/Downloads/google-chrome-stable_current_amd64.deb
```

The installed wrapper supports:

```bash
google-chrome-stable
google-chrome-stable update --check
google-chrome-stable update
google-chrome-stable uninstall
```

`update --check` verifies Google's signed `InRelease` metadata, downloads only
the package index, and sends an HTTP HEAD request to compare the package ETag.
It never downloads the `.deb`. The installer and wrapper require `gpg` for
this verification and pin Google's Linux Packages Signing Authority key.

The wrapper reads one flag per line from
`~/.config/chrome-flags.conf`. When a new package is detected, it opens a
local Chrome app dialog with Update now and Later actions. After installation,
the dialog offers Restart Chrome or Later.

The repository is self-contained and does not add an AUR or Google apt
repository. Chrome updates are intentionally manual.

`uninstall` removes only the local application, aliases, desktop entry,
update state and installer cache. The Chrome profile in `~/.config/google-chrome`
is preserved.
