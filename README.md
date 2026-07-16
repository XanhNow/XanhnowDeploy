# XanhnowDeploy

Central deployment repository for XanhNow Auth-module services.

Deployment flow:

```text
JWT_Refresh_Token_App        \
Auth_Login_App                \
Passkey_Provider_App           -> XanhnowDeploy -> API_Deploy -> api-1/api-2/api-3
SmartOtp_App                  /
```

This repository stores deployment orchestration only. Do not commit runtime secrets.

Runtime secrets must already exist on the target API nodes under `/etc/xanhnow/...`. The workflow verifies required files before restarting a service and fails if a required file is missing.

## Workflow

Use GitHub Actions workflow:

```text
Deploy Auth Apps
```

Inputs:

- `app`: `jwt-refresh-token`, `auth-login`, `passkey-provider`, `smart-otp`, or `all`
- `source_ref`: source branch, tag, or commit SHA
- `target_nodes`: `all`, `api-1`, `api-2`, `api-3`, or comma-separated list

If source repos are private, configure repository secret:

```text
XN_SOURCE_READ_TOKEN
```

The token only needs read access to the 4 source repositories.

## Target Nodes

- `api-1` -> `192.168.2.25`
- `api-2` -> `192.168.2.38`
- `api-3` -> `192.168.2.65`

The self-hosted runner on `API_Deploy` must have SSH aliases or DNS entries for `api-1`, `api-2`, and `api-3`.
