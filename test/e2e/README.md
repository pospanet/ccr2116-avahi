# End-to-end mDNS reflection lab

Ověřuje **skutečné paketové odrážení** přes dedikované izolované prostředí —
nejen konfigurační řádky.

## Topologie

```
        dedicated internal docker network "e2ewire-..."  (tagged trunk wire)
   ┌────────────────┬────────────────────┬────────────────────┐
 refl             c10                 c20                 c30
 eth0             eth0.10            eth0.20             eth0.30
 eth0.10 ── VID10 ─┤  (client on seg10; reflector listens eth0.10)
 eth0.20 ── VID20 ─┼───────────▶ reflected onto seg20
   (VLAN30 unmanaged → disallowed segment)
```

- **1 interní Docker síť** (`docker network create --internal`) = sdružený
  tagovaný „wire“. Linux bridge přenáší 802.1Q rámce.
- **Reflektor kontejner** = produkční runtime image, `BASE_IF=eth0`,
  `VLAN_LIST=10,20`, `IP_MODE=static` + `STATIC_MAP` → spravuje `eth0.10`,
  `eth0.20` a avahi na nich.
- **Každý klient** = samostatný kontejner (vlastní netns) připnutý k jednomu
  VLAN pod-rozhraní svého `eth0` → skutečná L2 izolace per netns (není
  loopback v jednom netns).

To, že klienti jsou **oddělené netns**, znamená, že paket z seg10 se na seg20
může dostat *jen* přes reflektor — není kernel cross-delivery.

## Co se ověřuje

| # | test | očekávané |
|---|---|---|
| 1 | announce na seg10 → posluchač na seg20 | přesné PTR/SRV:80/TXT `k=v`/A záznamy |
| 2 | query na seg20 → seg10 | reflektovaný paket nese **přesnou** otázku `Q _e2eq` + src refl seg10 IP |
| 3 | announce na **nespravovaném** VLAN30 → seg10 | **neodráží** se (listener ready+exit 0, sender __SENT__) |
| 4 | announce na seg10 → seg10 (loopback) | dorazí (same-segment kontrola) |
| 5 | avahi zastaveno → announce seg10 | **žádná** odraz na seg20 |
| 6 | `REFLECT_FILTERS=_e2eok` | matching plné záznamy; non-matching PTR/SRV/TXT potlačeny (A info) |
| 7 | **self-check**: listener na neexistujícím IF | wait_ready fail + nonzero exit (harness nefalšuje pass) |

Testy #3/#5 jsou negativní — protože listener se hlásí `__READY__` až po
bind+join a sender `__SENT__` po odeslání, prázdný capture je důvěryhodný
(nefalšuje se selháním klienta). Každý klient kontejner hlásí exit code;
neparsující paket = `<parse-error>`, ne tichý success.

Test #6 dokumentuje reálné chování avahi 0.9: `reflect-filters` filtruje
*služby* — cizí samotný A/AAAA adresní záznam se může přeposlat i bez
matching služby. To je známá sémantika avahi, ne chyba testu.

## Klient `mdns.py`

Stdlib-only Python: ručně encoduje/dekoduje DNS-SD pakety (PTR/SRV/TXT/A),
poslouchá na `224.0.0.251:5353` připnuté k jednomu rozhraní
(`IP_ADD_MEMBERSHIP` per-ifindex + `IP_MULTICAST_ALL=0`). Žádná závislost na
dbus/avahi klientovi.

## Build & run

```bash
# 1) runtime image (produkční)
docker build --platform linux/amd64 -t ccr2116-avahi:local-amd64 .
# 2) e2e image = runtime + python3 (jen pro test klienta)
docker build --platform linux/amd64 \
  --build-arg RUNTIME_IMAGE=ccr2116-avahi:local-amd64 \
  -f test/e2e/Dockerfile -t ccr2116-avahi-e2e:amd64 .
# 3) spusť lab
IMG=ccr2116-avahi:local-amd64 TESTIMG=ccr2116-avahi-e2e:amd64 \
  PLATFORM=linux/amd64 bash test/e2e/run.sh
```

Pro arm64 (QEMU): stejné, jen `--platform linux/arm64` a `-arm64` tagy.

Na Windows lze místo bash použít PowerShell wrapper:

```powershell
.\test\e2e\run.ps1 -Img ccr2116-avahi:local-amd64 -TestImg ccr2116-avahi-e2e:amd64 -Platform linux/amd64
```

(interně spustí `test/e2e/run.sh` přes Git-Bash nebo WSL bash.)

## Izolace & bezpečnost

- Používá **jen** dočasné kontejnery + interní síť, vše označené **přesným
  run-label `e2e-avahi-lab=<unikátní-run-id>`**. Cleanup maže **jen** zdroje s
  tímto label-em (nikdy cizí/předexistující kontejnery ani sítě).
- `--network none` není použitý (potřebujeme multi-netns), ale interní síť
  nemá výstup ven. Žádný `--privileged`, žádný SYS_ADMIN, žádný host network.
- E2e image je lokální test artefakt; nikdy se nepushuje.
