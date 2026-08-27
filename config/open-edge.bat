@echo off
REM open-edge.bat — opens Edge with a fake-DNS override for offline/air-gapped
REM PCs, where you can't edit C:\Windows\System32\drivers\etc\hosts (needs
REM admin) and can't rely on a wildcard DNS domain like nip.io either (needs
REM real internet DNS, which an offline PC doesn't have).
REM
REM --host-resolver-rules maps *.<domain> straight to 127.0.0.1 INSIDE Edge
REM itself, before any DNS lookup happens — no admin rights, no system files
REM touched, works fully offline. --user-data-dir gives this a separate Edge
REM profile/process so the flag actually takes effect even if you already
REM have a normal Edge window open elsewhere (Edge ignores these flags on a
REM second window of the SAME running instance).
REM
REM Usage:
REM   open-edge.bat                 uses domain "ping.local"
REM   open-edge.bat mydomain.local  uses a custom domain
REM
REM Set this same domain as INGRESS_DOMAIN in .env on THIS pc (not
REM 127.0.0.1.nip.io — that needs DNS this pc doesn't have). See
REM README.md's Ingress section / MANUAL.md section 9c.
REM
REM Every ping.local-style URL you type or click inside the Edge window this
REM opens will resolve to 127.0.0.1 for the life of that window — no need to
REM re-run this per URL, just once per browser session.

setlocal
set "DOMAIN=%~1"
if "%DOMAIN%"=="" set "DOMAIN=ping.local"
set "PROFILE=%TEMP%\ping-edge-offline-profile"

echo Opening Edge with *.%DOMAIN% mapped to 127.0.0.1 (separate profile: %PROFILE%)
start "" msedge.exe --user-data-dir="%PROFILE%" --host-resolver-rules="MAP *.%DOMAIN% 127.0.0.1" "https://login.%DOMAIN%"
