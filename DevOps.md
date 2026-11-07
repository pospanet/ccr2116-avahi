# Build & release poznámky

Cílová architektura RouterOS kontejneru na CCR2116 = **linux/arm64**.
Tag `X.Y.Z` níže je **pouze placeholder** — zvol vlastní verzi (např. `1.0.0`).

> **Prerekvizity**
>
> | OS | Potřebné |
> |---|---|
> | Windows | Docker Desktop (WSL2 backend), Git pro Windows (Git-Bash) nebo WSL distribuce, PowerShell 5.1+ |
> | macOS | Docker Desktop (nebo `colima`/`orbstack`), zsh (výchozí). Apple Silicon = nativní arm64 build; Intel = arm64 přes QEMU při `--platform linux/arm64` |
> | Linux | Docker Engine, bash |

---

## 1) Lokální build (bez push) — doporučený výchozí krok

**Pozor:** `docker buildx build` s `docker-container` driverem **nic nenačte** do
lokálního image store. Pro lokální run/save **musí** být `--load`, nebo použij
obyčejný `docker build` (výchozí docker driver, vidí lokální images — nutné i
pro závislé lokální image jako je e2e/dhcp test base).

### Produkční image (arm64 — cíl CCR2116)

```bash
# macOS (zsh) / Linux / Git-Bash — stejný příkaz
docker build --platform linux/arm64 -t ccr2116-avahi:X.Y.Z-arm64 .

# ekvivalent přes buildx s explicitním --load:
docker buildx build --platform linux/arm64 --load -t ccr2116-avahi:X.Y.Z-arm64 .
```

```powershell
# Windows PowerShell — stejné příkazy (docker CLI je nativní)
docker build --platform linux/arm64 -t ccr2116-avahi:X.Y.Z-arm64 .
docker buildx build --platform linux/arm64 --load -t ccr2116-avahi:X.Y.Z-arm64 .
```

### Nativní test image (amd64 — pro rychlé testy bez emulace)

```bash
docker build --platform linux/amd64 -t ccr2116-avahi:X.Y.Z-amd64 .
```

```powershell
docker build --platform linux/amd64 -t ccr2116-avahi:X.Y.Z-amd64 .
```

> **Apple Silicon (M1–M4):** arm64 build je nativní, `--platform linux/arm64`
> funguje přímo. **Intel Mac:** arm64 běží přes QEMU (Docker Desktop ho
> nastaví automaticky při `--platform`); amd64 je nativní.
>
> **Windows:** arm64 build běží přes QEMU/binfmt v Docker Desktop VM —
> funkční, ale pomalejší. amd64 je nativní.

---

## 2) Lokální ověření před release

Matice testovacích sad (detail: `test/VERIFICATION.md`, `README.md` § Testování):

| sada | počet | poznámka |
|---|---|---|
| `test/smoke.sh` | 60 | static runtime, validace, rollback, ack, shutdown |
| `test/runtime-security.sh` | 12 | 802.1Q/QinQ identita, preflight non-mutation, ack gating |
| `test/fixture-log.sh` | 3 | regrese shared-log race |
| `test/e2e/run.sh` | 8 | reálné mDNS pakety přes tagované VLAN |
| `test/dhcp/dhcp_lab.py` | 8 | reálný DHCP lease/renew/IPv4LL — **jen native amd64** |

### a) smoke + security + fixture (`--network none`, v kontejneru)

**macOS / Linux / Git-Bash:**

```bash
docker run --rm --platform linux/amd64 --network none \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --entrypoint /bin/bash -v "$PWD/test:/t:ro" \
  ccr2116-avahi:X.Y.Z-amd64 /t/smoke.sh

docker run --rm --platform linux/amd64 --network none \
  --cap-add NET_ADMIN --cap-add NET_RAW \
  --entrypoint /bin/bash -v "$PWD/test:/t:ro" \
  ccr2116-avahi:X.Y.Z-amd64 /t/runtime-security.sh

docker run --rm --platform linux/amd64 --network none \
  --entrypoint /bin/bash -v "$PWD/test:/t:ro" \
  ccr2116-avahi:X.Y.Z-amd64 /t/fixture-log.sh
```

**Windows PowerShell** (pozor: v PowerShell je `$PWD` objekt, použij `${PWD}`):

```powershell
docker run --rm --platform linux/amd64 --network none `
  --cap-add NET_ADMIN --cap-add NET_RAW `
  --entrypoint /bin/bash -v "${PWD}/test:/t:ro" `
  ccr2116-avahi:X.Y.Z-amd64 /t/smoke.sh

docker run --rm --platform linux/amd64 --network none `
  --cap-add NET_ADMIN --cap-add NET_RAW `
  --entrypoint /bin/bash -v "${PWD}/test:/t:ro" `
  ccr2116-avahi:X.Y.Z-amd64 /t/runtime-security.sh

docker run --rm --platform linux/amd64 --network none `
  --entrypoint /bin/bash -v "${PWD}/test:/t:ro" `
  ccr2116-avahi:X.Y.Z-amd64 /t/fixture-log.sh
```

> **Git-Bash na Windows:** `-v "$PWD/test:/t:ro"` funguje — `$PWD` je
> `/c/Users/...` a Docker Desktop to přeloží. Přímé `docker run` nepotřebuje
> `MSYS_NO_PATHCONV` (cesty jsou argv, ne bash-interpretované); wrappery
> `run.ps1`/`run.sh` ho nastavují interně pro své vlastní příkazy.

### b) e2e odrážení (8 testů, reálné pakety, interní síť)

Nejprve build e2e image (runtime + `python3` — čistě test artefakt, nikdy se
nepushuje/nenasazuje):

```bash
# macOS / Linux / Git-Bash / PowerShell — stejné
docker build --platform linux/amd64 \
  --build-arg RUNTIME_IMAGE=ccr2116-avahi:X.Y.Z-amd64 \
  -f test/e2e/Dockerfile -t ccr2116-avahi-e2e:amd64 .
```

**macOS / Linux / Git-Bash:**

```bash
IMG=ccr2116-avahi:X.Y.Z-amd64 TESTIMG=ccr2116-avahi-e2e:amd64 \
  PLATFORM=linux/amd64 bash test/e2e/run.sh
```

**Windows PowerShell** — doporučený wrapper nebo přímý Git-Bash:

```powershell
# Wrapper: env proměnné se předají JEN do child procesu (ne do vašeho shellu),
# interně spustí run.sh přes Git-Bash nebo WSL.
.\test\e2e\run.ps1 -Img ccr2116-avahi:X.Y.Z-amd64 -TestImg ccr2116-avahi-e2e:amd64 -Platform linux/amd64

# Nebo přímo přes Git-Bash (env prefix v -lc řetězci, ne v $env:):
& "C:\Program Files\Git\bin\bash.exe" -lc `
  "IMG=ccr2116-avahi:X.Y.Z-amd64 TESTIMG=ccr2116-avahi-e2e:amd64 PLATFORM=linux/amd64 bash test/e2e/run.sh"
```

Cleanup maže jen zdroje s run-labelem `e2e-avahi-lab=<unikátní-run-id>` — nikdy
cizí kontejnery/sítě (viz `test/e2e/README.md`).

### c) DHCP/IPv4LL lab (8 testů, ~5 min, **jen native amd64**)

Vyžaduje Docker + Python 3 (pouze stdlib). Používá namespace-scoped
`--sysctl net.ipv4.conf.default.promote_secondaries=1` **jen uvnitř netns
kontejnerů** — žádný host sysctl, žádný `--privileged`, žádný SYS_ADMIN.

**Linux / macOS na Intelu:**

```bash
python3 test/dhcp/dhcp_lab.py --base-image ccr2116-avahi:X.Y.Z-amd64 \
  --lab-image ccr2116-avahi-dhcp:X.Y.Z
# nebo build + run najednou (sestaví vlastní tagy):
python3 test/dhcp/dhcp_lab.py
```

> **Apple Silicon:** amd64 běží přes Rosetta → lab **není native amd64**,
> dhcpcd privsep socket může selhat (`Protocol not supported`). Spouštět jen
> pro diagnostiku, **ne jako akceptační výsledek**. Akceptace = native amd64.

**Windows PowerShell:**

```powershell
# Wrapper (najde python/py na PATH, předá přepínače):
.\test\dhcp\run.ps1 -BaseImage ccr2116-avahi:X.Y.Z-amd64

# nebo přímo:
python test\dhcp\dhcp_lab.py --base-image ccr2116-avahi:X.Y.Z-amd64 --lab-image ccr2116-avahi-dhcp:X.Y.Z
```

Na ARM64/QEMU a na RouterOS tento lab **není** akceptačním kritériem — viz
`test/dhcp/README.md`.

### d) Vulnerability scan (Trivy — reprodukce CI kroku)

```bash
# macOS / Linux / Git-Bash
docker save ccr2116-avahi:X.Y.Z-amd64 -o /tmp/ccr2116-avahi.tar
docker run --rm -v /tmp:/scan:ro aquasec/trivy:0.76.2 \
  image --input /scan/ccr2116-avahi.tar \
  --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1
```

```powershell
# Windows PowerShell
docker save ccr2116-avahi:X.Y.Z-amd64 -o "$env:TEMP\ccr2116-avahi.tar"
docker run --rm -v "${env:TEMP}:/scan:ro" aquasec/trivy:0.76.2 `
  image --input /scan/ccr2116-avahi.tar `
  --severity HIGH,CRITICAL --ignore-unfixed --exit-code 1
```

Kontejner CLI Trivy `--input` čte tar — žádný `docker.sock` mount, žádná
globální instalace. Politika CI: fail na fixable HIGH/CRITICAL (čistý scan
z jednoho data není trvalá záruka).

---

## 3) Export pro RouterOS

RouterOS umí importovat `.tar` image (`/container/add file=...`):

```bash
# macOS / Linux / Git-Bash / PowerShell — stejné
docker save ccr2116-avahi:X.Y.Z-arm64 -o ccr2116-avahi-X.Y.Z-arm64.tar
```

Pak upload na router (Winbox / Files / SCP) a postup podle
`examples/routeros.rsc` (KROK 1–3). **Produkční režim: `IP_MODE=static`** —
dynamické režimy (`dhcp`, `linklocal`) nejsou na RouterOS ověřené (RouterOS
nemá `--sysctl` jako container property, takže prerekvizita
`promote_secondaries` z dhcpcd tam pravděpodobně nejde nastavit).

---

## 4) Publish — pouze explicitně, ručně, na Docker Hub

`--push` jde rovnou do registry (žádný `--load`, žádný `docker save`) —
jeden `buildx` krok buildne arm64 image a pushne ho na Docker Hub.

Každý release pushne **všechny tři tagy najednou**: verzi, verzi s `-arm64`
sufixem a `latest` (všechny ukazují na tentýž arm64 image).

```bash
# macOS / Linux / Git-Bash / PowerShell — stejné
docker login

# Cíl: Docker Hub repo pospa/ccr2116-avahi, čistě linux/arm64 (CCR2116).
# Jediný příkaz buildne + pushne všechny tagy najednou.
docker buildx build --platform linux/arm64/v8 \
  -t pospa/ccr2116-avahi:X.Y.Z \
  -t pospa/ccr2116-avahi:X.Y.Z-arm64 \
  -t pospa/ccr2116-avahi:latest \
  --push .
```

```powershell
# Windows PowerShell — identické
docker login
docker buildx build --platform linux/arm64/v8 `
  -t pospa/ccr2116-avahi:X.Y.Z `
  -t pospa/ccr2116-avahi:X.Y.Z-arm64 `
  -t pospa/ccr2116-avahi:latest `
  --push .
```

**Pozn.:**

- Nepoužívat `--push` bez předchozího lokálního ověření (krok 2).
- `--platform linux/arm64/v8` = ARMv8 explicitní variant (odpovídá CCR2116
  ARM64 SoC); `linux/arm64` je ekvivalent, `v8` je přesnější.
- `docker build` nemá `--push` — pro push použij `buildx` (nebo `docker
  build` + `docker tag` + `docker push` ve více krocích).
- **`latest` se přepisuje** — každý release posune `latest` na nový image;
  verzní tagy (`X.Y.Z`, `X.Y.Z-arm64`) zůstávají neměnné.
- Po push ověř digest / platformu / všechny tagy:
  `docker buildx imagetools inspect pospa/ccr2116-avahi:latest`.
- **image = jen arm64** — na hubu budou všechny tagy arm64 manifest; RouterOS
  stáhne ten. Žádný multi-arch manifest se nevytváří (cíl je čistě CCR2116).
- Base image `alpine:3.24.4` není digest-pinned a `apk` balíčky se mohou
  aktualizovat — pro plnou reprodukovatelnost zvaž pin digestu
  (`FROM alpine:3.24.4@sha256:<digest>`), viz `README.md` § Omezení.

---

## Rychlá reference — požadované capabilities

| úkon | capabilities / flagy | poznámka |
|---|---|---|
| build | žádné | `docker build` / `buildx --load` |
| smoke / security / fixture | `NET_ADMIN` + `NET_RAW` | `--network none`, read-only mount `/t` |
| e2e | `NET_ADMIN` + `NET_RAW` | interní docker síť, label-scoped cleanup |
| dhcp lab | `NET_ADMIN` + `NET_RAW` + `--sysctl net.ipv4.conf.default.promote_secondaries=1` | **jen native amd64** |
| produkce (RouterOS) | dle `examples/routeros.rsc` | `IP_MODE=static` doporučeno |
