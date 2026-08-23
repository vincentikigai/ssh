# Shared SSH setup

These scripts install the shared `config` file as `~/.ssh/config` and keep a
backup of any existing local SSH config. Store this folder in a location that
is available to each user, such as a shared OneDrive folder.

## Before running setup

- Install OpenSSH (`ssh` must be available in the terminal).
- Give each user access to this folder.
- Keep private keys out of Git and share them separately with only the users
	who need them.
- Update `config` with host aliases, usernames, and key paths. Prefer paths
	that exist on the target operating system.

## Windows

Open PowerShell in this folder and run:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows-setup.ps1
```

The script creates `%USERPROFILE%\.ssh`, creates `config_local` if needed,
backs up an existing `config`, creates the symbolic link, and applies the
OpenSSH ACLs. If symbolic-link creation requires elevation, approve the UAC
prompt.

For troubleshooting, run:

```powershell
.\windows-setup.ps1 -DebugMode
```

The debug log is written beside the script as `setup_debug.log`.

## macOS and Linux

Run the Unix setup script from this folder:

```bash
chmod +x unix-setup.sh
./unix-setup.sh
```

The script creates `~/.ssh`, backs up an existing `config`, links the shared
config, and sets restrictive file permissions.

## Verify the setup

List the resolved settings for a host alias without connecting:

```bash
ssh -G <host-alias>
```

Then test the connection:

```bash
ssh <host-alias>
```

Use `ssh -v <host-alias>` for connection diagnostics. If a host fails, first
check that its `IdentityFile` exists locally and that the private key
permissions are restricted.

## Sharing tips

- Share the scripts and host aliases, not private key files.
- Use placeholders or a separate private config when host details should not
	be shared with everyone who can access the folder.
- Each user should run the setup script under their own account so `~/.ssh`
	and file permissions are applied to the correct profile.
- The setup scripts are safe to rerun: an existing physical SSH config is
	renamed with a timestamp before the link is created.