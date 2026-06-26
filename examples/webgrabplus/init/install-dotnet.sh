# Custom init script for the WebGrab+Plus container.
# The LinuxServer.io WebGrab+Plus image is based on Alpine but does not
# ship a .NET runtime. WGP V5.6.0+ requires .NET 9. This script installs it
# idempotently at container start-up.
#!/bin/bash
if ! command -v dotnet >/dev/null 2>&1; then
    echo "[custom-init] Installing .NET 9 runtime..."
    apk add --no-cache dotnet9-runtime dotnet-host >/dev/null 2>&1
    ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet 2>/dev/null || true
    echo "[custom-init] .NET 9 installed"
else
    echo "[custom-init] dotnet already present"
fi
