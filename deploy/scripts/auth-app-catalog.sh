#!/usr/bin/env bash
set -Eeuo pipefail

resolve_apps() {
  local selected="${SELECTED_APP:?SELECTED_APP is required}"
  case "$selected" in
    jwt-refresh-token) echo "jwt-refresh-token" ;;
    auth-login) echo "auth-login" ;;
    passkey-provider) echo "passkey-provider" ;;
    smart-otp) echo "smart-otp" ;;
    all) echo "jwt-refresh-token auth-login passkey-provider smart-otp" ;;
    *) echo "FAIL: invalid app: $selected" >&2; exit 1 ;;
  esac
}

resolve_nodes() {
  local nodes="${TARGET_NODES:-api-1}"
  echo "$nodes" | tr ',' ' ' | xargs -n1 | while read -r node; do
    case "$node" in
      api-1|api-2|api-3) echo "$node" ;;
      *) echo "FAIL: invalid target node: $node" >&2; exit 1 ;;
    esac
  done | xargs
}

source_repo_for_app() {
  case "$1" in
    jwt-refresh-token) echo "XanhNow/JWT_Refresh_Token_App" ;;
    auth-login) echo "XanhNow/Auth_Login_App" ;;
    passkey-provider) echo "XanhNow/Passkey_Provider_App" ;;
    smart-otp) echo "XanhNow/SmartOtp_App" ;;
    *) echo "FAIL: unknown app: $1" >&2; exit 1 ;;
  esac
}

components_for_app() {
  case "$1" in
    smart-otp) echo "smart-otp-grpc smart-otp-worker" ;;
    jwt-refresh-token|auth-login|passkey-provider) echo "$1" ;;
    *) echo "FAIL: unknown app: $1" >&2; exit 1 ;;
  esac
}

project_for_component() {
  case "$1" in
    jwt-refresh-token) echo "GrpcTokenProvider.Grpc/GrpcTokenProvider.Grpc.csproj" ;;
    auth-login) echo "src/XanhNow.Auth.Login.Api/XanhNow.Auth.Login.Api.csproj" ;;
    passkey-provider) echo "src/XanhNow.PasskeyProvider.Grpc/XanhNow.PasskeyProvider.Grpc.csproj" ;;
    smart-otp-grpc) echo "src/XanhNow.Auth.SmartOtp.Grpc/XanhNow.Auth.SmartOtp.Grpc.csproj" ;;
    smart-otp-worker) echo "src/XanhNow.Auth.SmartOtp.Worker/XanhNow.Auth.SmartOtp.Worker.csproj" ;;
    *) echo "FAIL: unknown component: $1" >&2; exit 1 ;;
  esac
}

dll_for_component() {
  case "$1" in
    jwt-refresh-token) echo "GrpcTokenProvider.Grpc.dll" ;;
    auth-login) echo "XanhNow.Auth.Login.Api.dll" ;;
    passkey-provider) echo "XanhNow.PasskeyProvider.Grpc.dll" ;;
    smart-otp-grpc) echo "XanhNow.Auth.SmartOtp.Grpc.dll" ;;
    smart-otp-worker) echo "XanhNow.Auth.SmartOtp.Worker.dll" ;;
    *) echo "FAIL: unknown component: $1" >&2; exit 1 ;;
  esac
}

service_for_component() {
  case "$1" in
    jwt-refresh-token) echo "xanhnow-auth-jwt-refresh-token" ;;
    auth-login) echo "xanhnow-auth-login" ;;
    passkey-provider) echo "xanhnow-passkey-provider" ;;
    smart-otp-grpc) echo "xanhnow-auth-smart-otp-grpc" ;;
    smart-otp-worker) echo "xanhnow-auth-smart-otp-worker" ;;
    *) echo "FAIL: unknown component: $1" >&2; exit 1 ;;
  esac
}

base_dir_for_component() {
  case "$1" in
    jwt-refresh-token) echo "/srv/xanhnow/apps/jwt-refresh-token" ;;
    auth-login) echo "/srv/xanhnow/apps/auth-login" ;;
    passkey-provider) echo "/srv/xanhnow/apps/passkey-provider" ;;
    smart-otp-grpc) echo "/opt/xanhnow/auth-smart-otp/grpc" ;;
    smart-otp-worker) echo "/opt/xanhnow/auth-smart-otp/worker" ;;
    *) echo "FAIL: unknown component: $1" >&2; exit 1 ;;
  esac
}

health_mode_for_component() {
  case "$1" in
    jwt-refresh-token) echo "http" ;;
    auth-login) echo "http" ;;
    passkey-provider) echo "h2c" ;;
    smart-otp-grpc|smart-otp-worker) echo "none" ;;
    *) echo "FAIL: unknown component: $1" >&2; exit 1 ;;
  esac
}

health_path_for_component() {
  case "$1" in
    jwt-refresh-token) echo ":5102/healthz" ;;
    auth-login) echo ":8080/health/ready" ;;
    passkey-provider) echo ":5101/healthz" ;;
    smart-otp-grpc) echo ":5104/healthz" ;;
    smart-otp-worker) echo "/" ;;
    *) echo "FAIL: unknown component: $1" >&2; exit 1 ;;
  esac
}

clone_source() {
  local repo="$1"
  local ref="$2"
  local destination="$3"
  local url="https://github.com/${repo}.git"

  if [[ -n "${SOURCE_READ_TOKEN:-}" ]]; then
    url="https://x-access-token:${SOURCE_READ_TOKEN}@github.com/${repo}.git"
  fi

  rm -rf "$destination"
  git init "$destination" >/dev/null
  git -C "$destination" remote add origin "$url"
  git -C "$destination" fetch --depth 1 origin "$ref"
  git -C "$destination" checkout --detach FETCH_HEAD >/dev/null
  git -C "$destination" remote remove origin
}

write_component_runtime_contract() {
  local component="$1"
  local env_file="$2"
  local required_file="$3"

  : > "$env_file"
  : > "$required_file"

  case "$component" in
    jwt-refresh-token)
      cat > "$env_file" <<ENV
Environment=Grpc__Port=5102
Environment=Grpc__ListenLocalhost=false
Environment=Grpc__UseTls=false
Environment=Vault__RoleIdFile=/etc/xanhnow/jwt-refresh-token/vault/role_id
Environment=Vault__SecretIdFile=/etc/xanhnow/jwt-refresh-token/vault/secret_id
Environment=Vault__CaCertFile=/etc/xanhnow/jwt-refresh-token/trust/vault-ca.crt
ENV
      cat > "$required_file" <<REQ
/etc/xanhnow/jwt-refresh-token/vault/role_id
/etc/xanhnow/jwt-refresh-token/vault/secret_id
/etc/xanhnow/jwt-refresh-token/trust/vault-ca.crt
REQ
      ;;
    auth-login)
      cat > "$env_file" <<ENV
Environment=ASPNETCORE_URLS=http://0.0.0.0:8080
Environment=Infrastructure__Mode=RedisVault
Environment=Vault__RoleIdFile=/etc/xanhnow/auth-login/vault/api-role-id
Environment=Vault__SecretIdFile=/etc/xanhnow/auth-login/vault/api-secret-id
Environment=Vault__CaCertFile=/etc/xanhnow/auth-login/trust/vault-ca.crt
ENV
      cat > "$required_file" <<REQ
/etc/xanhnow/auth-login/vault/api-role-id
/etc/xanhnow/auth-login/vault/api-secret-id
/etc/xanhnow/auth-login/trust/vault-ca.crt
REQ
      ;;
    passkey-provider)
      cat > "$env_file" <<ENV
Environment=Grpc__Port=5101
Environment=Grpc__RequireMtls=false
Environment=Vault__RoleIdFile=/etc/xanhnow/passkey/vault/role_id
Environment=Vault__SecretIdFile=/etc/xanhnow/passkey/vault/secret_id
Environment=Vault__CaCertFile=/etc/xanhnow/passkey/trust/vault-ca.crt
ENV
      cat > "$required_file" <<REQ
/etc/xanhnow/passkey/vault/role_id
/etc/xanhnow/passkey/vault/secret_id
/etc/xanhnow/passkey/trust/vault-ca.crt
REQ
      ;;
    smart-otp-grpc)
      cat > "$env_file" <<ENV
Environment=Grpc__Port=5104
Environment=Vault__RoleIdFile=/etc/xanhnow/auth-smart-otp/credentials/api-role-id
Environment=Vault__SecretIdFile=/etc/xanhnow/auth-smart-otp/credentials/api-secret-id
Environment=Vault__CaCertificatePath=/etc/xanhnow/auth-smart-otp/trust/vault-ca.crt
ENV
      cat > "$required_file" <<REQ
/etc/xanhnow/auth-smart-otp/credentials/api-role-id
/etc/xanhnow/auth-smart-otp/credentials/api-secret-id
/etc/xanhnow/auth-smart-otp/trust/vault-ca.crt
/etc/xanhnow/auth-smart-otp/mtls/server/smart-otp-server.crt
/etc/xanhnow/auth-smart-otp/mtls/server/smart-otp-server.key
/etc/xanhnow/auth-smart-otp/mtls/ca/smart-otp-grpc-client-ca.crt
REQ
      ;;
    smart-otp-worker)
      cat > "$env_file" <<ENV
Environment=Vault__RoleIdFile=/etc/xanhnow/auth-smart-otp/credentials/worker-role-id
Environment=Vault__SecretIdFile=/etc/xanhnow/auth-smart-otp/credentials/worker-secret-id
Environment=Vault__CaCertificatePath=/etc/xanhnow/auth-smart-otp/trust/vault-ca.crt
ENV
      cat > "$required_file" <<REQ
/etc/xanhnow/auth-smart-otp/credentials/worker-role-id
/etc/xanhnow/auth-smart-otp/credentials/worker-secret-id
/etc/xanhnow/auth-smart-otp/trust/vault-ca.crt
REQ
      ;;
    *) echo "FAIL: unknown component: $component" >&2; exit 1 ;;
  esac
}
