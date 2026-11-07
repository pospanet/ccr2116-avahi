# Avahi mDNS reflektor pro MikroTik CCR2116 / RouterOS container

Minimalistický linux/arm64 image, který v RouterOS containeru provozuje
**čistý mDNS reflektor** (avahi-daemon v režimu `enable-reflector=yes`) nad
802.1Q VLAN pod- rozhraními trunkového portu. Slouží k tomu, aby klienti v
různých VLAN viděli mDNS/DNS-SD služby mezi sebou, aniž by se VLAN L3
propojovaly.

> **Stav projektu:**
> * **Statický runtime + mDNS odrážení**: lokálně ověřeno
>   `test/smoke.sh` **60/60**, `test/runtime-security.sh` **12/12**,
>   `test/e2e/run.sh` **8/8** (reálné pakety přes tagované VLAN; amd64
>   a emulované arm64). Na amd64 prošlo také **5 po sobě jdoucích běhů**
>   smoke + security. Dřívější zdánlivé zaseknutí byl závod ve sdíleném
>   testovacím logu; opravu hlídá `test/fixture-log.sh` (**3/3**).
>   Podrobnosti a meze ověření: [test/VERIFICATION.md](test/VERIFICATION.md).
> * **DHCP / IPv4LL**: **lab-ověřené na native amd64** (reálné lease, renew,
>   fallback→DHCP přechod, timeout bez serveru, obnovení po výpadku —
>   `test/dhcp/`, 8/8) za podmínky namespace-scoped sysctl
>   `net.ipv4.conf.default.promote_secondaries=1`. **Na ARM64 pod QEMU
>   dhcpcd selže** (privsep socket `Protocol not supported` — pozorované
>   omezení emulace, ne nutně chyba upstream). **Na skutečném RouterOS/
>   ARM64 cíli DHCP/LL stále NENÍ ověřené** — produkčně doporučujeme
>   `IP_MODE=static`, dokud není validováno na cíli.
> * **RouterOS nasazení**: neověřené — `examples/routeros.rsc` je pouze
>   komentovaná šablona (syntax RouterOS 7.26).

---

## Jak to funguje

1. Entrypoint (supervizor v `/entrypoint.sh`) načte konfiguraci z env
   proměnných, **všechno nejdřív zvaliduje** (žádná změna sítě před validací).
2. Na trunk rozhraní (`BASE_IF`, autodetekce nebo explicitní) vytvoří VLAN
   pod-rozhraní `<BASE_IF>.<vid>` pro každé `vid` v `VLAN_LIST`.
3. Přiřadí adresu podle `IP_MODE`:
   - `static` — přesná adresa ze `STATIC_MAP` (idempotentní, exact reuse),
   - `dhcp` / `linklocal` — přes **dhcpcd** (jediný adresní manager, žádný
     udhcpc/zcip/avahi-autoipd fallback).
4. Vygeneruje `avahi-daemon.conf` z šablony: čistý reflektor
   (`disable-publishing=yes`, `enable-dbus=no`, `use-ipv6=no`,
   `allow-interfaces=<jen spravovaná rozhraní>`).
5. Spustí avahi-daemon; **ready** = avahi ohlásil vlastní
   "Server startup complete" (ack) **a** všechna rozhraní mají očekávanou
   adresu. Ne samotný běž procesu.

### Log reader / readiness

Avahi 0.9 nemá machine-readable "ready" protokol. Jediný skutečný signál
dokončené inicializace je log-řádka z callbacku `AVAHI_SERVER_RUNNING`. Stderr
daemonu proto běží přes **vlastní FIFO do trackovaného readeru**, který každou
řádku přeposílá na stderr kontejneru a při "Server startup complete" zapíše
`ready`-ack marker. Reader je essential — když umře, supervizor skončí a
healthcheck zrudne (žádný stale-green).

## Konfigurace (env proměnné)

| proměnná | výchozí | význam |
|---|---|---|
| `VLAN_LIST` | **povinné** | čárkou dělené VLAN id 1..4094, např. `10,20,300` |
| `BASE_IF` | autodetekce | trunk rozhraní. Musí existovat, nebýt `lo`, nebýt VLAN child |
| `IP_MODE` | `dhcp` | `dhcp` \| `static` \| `linklocal` |
| `STATIC_MAP` | — | povinné při `static`: `VID:IPv4/prefix`, např. `10:192.168.10.250/24` |
| `EXTRA_INTERFACES` | — | čárkou dělená *předkonfigurovaná* rozhraní (UP + IPv4); nesmí být trunk ani se překrývat se spravovanými VLAN (jiná předkonfigurovaná VLAN rozhraní jsou povolená) |
| `REFLECT_FILTERS` | — | čárkou dělené DNS-SD názvy/typy; prázdné = odrážet vše (warning) |
| `DHCP_FALLBACK_LL` | `false` | jen při `dhcp`: `true` = povolit IPv4LL fallback, `false` = `noipv4ll` |
| `INTERFACE_WAIT_TIMEOUT` | `30` | s; čekání na trunk rozhraní (1..86400, normalizováno na decimal) |
| `STARTUP_TIMEOUT` | `60` | s; čekání na ready (avahi ack + adresy) |
| `LOG_LEVEL` | `info` | `info` \| `debug` (`--debug` pro avahi) |

### Příklad — static (doporučeno do ověření DHCP na cíli)

```bash
docker run -d --name mdns-reflector \
  --network <trunk-network> --cap-add NET_ADMIN --cap-add NET_RAW \
  -e VLAN_LIST=10,20 \
  -e BASE_IF=eth0 \
  -e IP_MODE=static \
  -e STATIC_MAP='10:192.168.10.250/24,20:192.168.20.250/24' \
  ccr2116-avahi:<tag>
```

### Příklad — dhcp / linklocal (amd64 lab-ověřené; RouterOS/ARM64 neověřené)

```bash
# DHCP
docker run -d --name mdns-reflector \
  --network <trunk-network> --cap-add NET_ADMIN --cap-add NET_RAW \
  --sysctl net.ipv4.conf.default.promote_secondaries=1 \
  -e VLAN_LIST=10,20 -e BASE_IF=eth0 -e IP_MODE=dhcp \
  ccr2116-avahi:<tag>

# IPv4 link-local (169.254/16) přes dhcpcd - na amd64 labu ověřené,
# na RouterOS / ARM64 zatím ne. Vyžaduje namespace-scoped sysctl:
docker run -d --name mdns-reflector \
  --network <trunk-network> --cap-add NET_ADMIN --cap-add NET_RAW \
  --sysctl net.ipv4.conf.default.promote_secondaries=1 \
  -e VLAN_LIST=10,20 -e BASE_IF=eth0 -e IP_MODE=linklocal \
  ccr2116-avahi:<tag>
```

> **⚠ DHCP/IPv4LL — lab-ověřené na native amd64, na cíli zatím experimentální.**
> Režim je implementován čistě přes **dhcpcd 10.5.2** (jediný adresní manager).
>
> *Co `test/dhcp/` (8/8, native amd64, ~5 min) prokázalo:* reálný DHCP **lease**
> (server `DHCPACK` + lease file + klient `BOUND`), **renewal** (nový ACK/REQUEST
> bez nového DISCOVER/OFFER, lease expiry posunutý), **IPv4LL** claim přes ARP
> probing (2 odlišné adresy), **fallback→DHCP přechod** (LL staženo po serveru),
> **timeout bez serveru** + **obnovení po výpadku serveru**. Podmínkou je
> **namespace-scoped** sysctl `net.ipv4.conf.default.promote_secondaries=1`
> (`docker run --sysctl ...`) — platí jen uvnitř netns kontejneru, **žádné**
> host/sysctl/`--privileged`/SYS_ADMIN/`/proc` mount.
>
> *Co NENÍ ověřeno:* běh na **ARM64** (pod QEMU dhcpcd privsep selhává —
> `Protocol not supported` — pozorované omezení emulace) a hlavně **skutečný
> RouterOS** (tam `--sysctl` není podporovaná property kontejneru). RouterOS
> `--sysctl` **neexistuje** — nejde o přenositelný předpoklad. Dokud není
> validováno na cíli, produkčně používejte `IP_MODE=static`.
>
> *Pozn.:* ve výchozím neprivilegovaném prostředí (bez sysctl) dhcpcd spadne
> s jasnou chybou — `test/smoke.sh` to ověřuje jako očekávaný stav tohoto
> prostředí, **ne** jako univerzální „dhcpcd nejde spustit“ (viz `test/dhcp/`).

## Bezpečnostní model

- **Odraz je all-to-all**: avahi odráží mezi *všemi* povolenými rozhraními.
  Není to firewall, není směrové, není autentizace. `REFLECT_FILTERS` omezují
  *které služby* se odrážejí (podle jména služby/typu/stroje), ne bezpečnostní
  politiku.
- **`REFLECT_FILTERS` není bezpečnostní hranice**: u služby, která filtr
  nesplní, avahi 0.9 potlačí její PTR/SRV/TXT záznamy, **ale holý A (a
  potenciálně AAAA) adresní záznam hostitele stejně přepošle**. Filtr tedy
  neslouží k utajení/izolaci hostitele — jen k omezení, které *služby* se
  propagují.
- **Nepoužívejte více překrývajících se reflektorů** mezi stejnými sítěmi —
  způsobily by ping-pong mDNS paketů (viz man avahi-daemon.conf).
- **IPv4 transport ≠ IPv6 záznamy**: `use-ipv6=no` a `reflect-ipv=no`, ale
  cizí mDNS oznámení můžou nést AAAA záznamy v IPv4 transportu — avahi je jen
  přeposílá.
- **Privilegie**: entrypoint startuje jako root (potřebuje `NET_ADMIN` na
  linkové změny), samotný avahi-daemon se sám zbaví práv (`drop root`+chroot),
  jak umožňuje jeho build. Nepoužíváme `--privileged` ani SYS_ADMIN.
- **Multicast scope**: odráží se jen mezi `allow-interfaces` — trunk sám o sobě
  do `allow-interfaces` nepatří, jen jeho VLAN childy (+ případné `EXTRA_INTERFACES`).
- **Koexistence s CUPS/AirPrint kontejnerem** (např. `chuckcharlie/cups-avahi-airprint`):
  každý kontejner má **vlastní veth** a vlastní netns — nesdílejte jedno rozhraní
  ani IP adresy. Reflektor má `EXPOSE 5353/udp` jen jako metadata; CUPS Avahi
  publisher běží ve svém netns a porty si neblokují. Reflektor **bude odrážet
  AirPrint inzerce (`_ipp._tcp`, `_universal._sub._ipp._tcp`) do všech povolených
  VLAN** — to je záměr all-to-all. Nepřidávejte na stejnou množinu VLAN druhý
  aktivní mDNS reflektor (ping-pong); CUPS image reflektor **není** (je to
  publisher, `enable-reflector` není zapnutý). Chcete-li AirPrint jen na
  vybraných VLAN, potřebujete **omezit VLAN_LIST** (nebo oddělený reflektor na
  jiné VLAN), ne se spoléhat na `REFLECT_FILTERS` — to není bezpečnostní hranice.
- **⚠ CUPS port 631/TCP je samostatný problém od mDNS 5353/UDP.** Upstream
  image ([Dockerfile@master](https://github.com/chuckcharlie/cups-avahi-airprint/blob/master/Dockerfile),
  [run_cups.sh](https://github.com/chuckcharlie/cups-avahi-airprint/blob/master/root/root/run_cups.sh))
  v `cupsd.conf` nastavuje `Listen 0.0.0.0:631` a do `<Location />` i
  `<Location /admin/conf>` vkládá `Allow All`; dále `ServerAlias *` a
  `DefaultEncryption Never`. Port 631/TCP tedy **poslouchá na všech
  rozhraních** a web UI + IPP jsou dosažitelné pro každého klienta na
  připojené L2/VLAN (a dál přes routing), nejen pro mDNS. `EXPOSE 631` sám
  firewall neotevírá, ale samotný binding znamená reálnou konektivitu.
  Webadmin `<Location /admin>` vyžaduje `Require user @SYSTEM`
  (CUPSADMIN/CUPSPASSWORD), ale `<Location />` a `<Location /admin/conf>`
  mají `Allow All` — i anonymní tisk (v2.0+ záměrně pro AirPrint) a
  konfigurační endpoint jsou bez autentizace. Nevystavujte ani neroutujte
  tento port do nedůvěryhodných sítí: omezte jej na RouterOS úrovni vlastní
  validovanou politikou (VLAN membership, bridge horizon, firewall filter —
  specifické pro vaši síť). Před nasazením ověřte aktuální tag/digest a
  `cupsd.conf` příslušné verze — `latest` se mění.

## Chování při startu/vypnutí (rollback)

- **Failed start** (`STARTUP_OK=0`): vrátí se zpět jen změny, které jsme
  udělali na linkách, které jsme *nevytvořili* — smaže se jen přesná adresa,
  kterou jsme přidali (dle ifindex+CIDR), obnoví se flagy UP/MULTICAST, které
  jsme změnili. Vytvořené VLAN linky se smažou vždy.
- **Successful stop** (`STARTUP_OK=1`): záměrná, plně aplikovaná statická
  adresa na *předexistujícím* linku zůstane (uživatel si ji přál). Vytvořené
  VLAN linky se smažou.
- Konflikty (cizí IPv4 na spravovaném VLAN, duplicitní/shodné jméno cizího
  linku) se **odmítnou v preflight před jakoukoli mutací**.

## Omezení / poznámky

- **Jména rozhraní**: ASCII písmena, číslice a `._-`; složené `<BASE_IF>.<vid>`
  max **15 znaků** (IFNAMSIZ). QinQ (vnořené 802.1Q) **není podporováno** —
  akceptuje se jen čistý 802.1Q VLAN child s daným id a parentem.
- **169.254/16 je vyhrazené** pro `linklocal` režim — ve `static` se odmítá.
- **`REFLECT_FILTERS` charset**: jen DNS-safe znaky (`A-Z a-z 0-9 . _ -`) —
  žádná mezera/čárka/meta uvnitř tokenu. Typy jako `_ipp._tcp.local` jsou OK.
- **`STATIC_MAP` CIDR**: `VID:IPv4/prefix`; IPv4 oktety **nesmí mít leading
  zeros** (`010` se odmítá, ne čte jako 8); kanonizuje se na kernel formu.
  Prefix 1..32 (`/31`,`/32` povoleny). `169.254/16` a 127/8 a multicast se
  ve `static` odmítají.
- **`EXPOSE 5353/udp`** je jen metadata; neotvírá firewall.
- **Healthcheck** (`/healthcheck.sh`) ověřuje ready-file, avahi ack, živost
  vlastněných procesů a stav rozhraní/adres — **ne** end-to-end důkaz
  odrážení (k tomu je `test/e2e`).
- **IPv4LL konfliktová obrana**: ověřeno ARP probing a dvě různé přidělené
  adresy; zotavení po vynucené ARP kolizi zatím otestované není.
- **Base image `alpine:3.24.4`** používá repozitáře `v3.24`; `apk` balíčky se
  můžou aktualizovat. `FROM` tag **nepinuje** všechny apk závislosti ani
  digest — pro plnou reprodukovatelnost zvažte pin digestu.
- **dbus knihovny** mohou zůstat tranzitivně nainstalované, ale avahi běží s
  `enable-dbus=no` a žádný dbus-daemon se nespouští.
- **Závislé nástroje**: žádný runtime python/perl; e2e test image přidává
  `python3` pouze pro test klienta (stdlib), není součástí produkčního image.

## Testování — matice

| sada | co ověřuje | kde běží | výsledek |
|---|---|---|---|
| `test/smoke.sh` | statický runtime, validace, rollback, ack, shutdown (60 testů) | `--network none`, amd64 i arm64 | **60/60**, na amd64 5× po sobě |
| `test/runtime-security.sh` | 802.1Q typ, cizí VID, parent, QinQ, jména, preflight non-mutation, ack gating | `--network none`, amd64 i arm64 | **12/12** |
| `test/e2e/run.sh` | reálné mDNS pakety přes tagované VLAN: pozitiv, dotaz, izolace, loopback, stop, filtry, harness self-check | interní Docker síť, amd64 i arm64 (emulace) | **8/8** |
| `test/dhcp/dhcp_lab.py` | skutečný DHCP lease/renew/IPv4LL/fallback/timeout/obnova | interní síť, **jen native amd64** | **8/8** |
| `test/fixture-log.sh` | log je vyprázdněný v rodiči před spuštěním další fixture; kontrola původní chyby | `--network none`, bez extra capabilities | **3/3** |

### Smoke + security (`--network none`)

Běží uvnitř runtime image; dummy/veth stojí za trunk; static režim je plně
cvičený. DHCP/linklocal se zde ověřuje jen jako **jasná chyba** (omezení
prostředí — ne funkční DHCP test; ten řeší `test/dhcp`):

```bash
docker run --rm --platform linux/amd64 --network none \
  --cap-add NET_ADMIN --cap-add NET_RAW --entrypoint /bin/bash \
  -v "$PWD/test:/t:ro" <image> /t/smoke.sh
docker run --rm --platform linux/amd64 --network none \
  --cap-add NET_ADMIN --cap-add NET_RAW --entrypoint /bin/bash \
  -v "$PWD/test:/t:ro" <image> /t/runtime-security.sh
```

### End-to-end odrážení (8 testů, reálné pakety)

Dedikovaná *interní* Docker síť = tagovaný "wire"; reflektor kontejner +
oddělené klientské kontejnery (každý vlastní netns, jedno VLAN pod-rozhraní).
Ověřuje pozitivní odrážení (PTR/SRV/TXT/A), odrážení dotazu, izolaci
nespravovaného VLAN, loopback v rámci segmentu, vypnutí avahi = žádná odraz,
a filtry (matching vs non-matching). Viz `test/e2e/run.sh`:

```bash
# build runtime + test image, pak:
IMG=<runtime-image> TESTIMG=<e2e-image> PLATFORM=linux/amd64 bash test/e2e/run.sh
```

### DHCP/IPv4LL lab (8 testů, native amd64)

Reálný dhcpcd proti reálnému dnsmasq serveru na interní tagované síti.
Vyžaduje jen Docker + Python 3 (stdlib), **žádné** host nastavení:

```bash
python test/dhcp/dhcp_lab.py                 # build images + run all
python test/dhcp/dhcp_lab.py --skip-build \
  --base-image <runtime-image> --lab-image <dhcp-test-image>
```

Namespace-scoped prerekvizita `--sysctl net.ipv4.conf.default.promote_secondaries=1`
je nastavena **jen kontejnerům** (žádný host sysctl, žádný `--privileged`,
žádný SYS_ADMIN). Funguje jen na **native amd64** — na ARM64/QEMU a na
skutečném RouterOS zatím není ověřené. Viz `test/dhcp/README.md`.

E2e image je jen testovací (runtime + `python3`), nikdy se nenasazuje.

## Migrace ze starší verze (3.20-era)

| staré chování | nové |
|---|---|
| `IP_MODE` default `linklocal` | nyní **`dhcp`** |
| DHCP fallback na IPv4LL zapnutý | `DHCP_FALLBACK_LL` default **`false`** (`noipv4ll`) |
| — | nové env `INTERFACE_WAIT_TIMEOUT`, `STARTUP_TIMEOUT`, `REFLECT_FILTERS`, `LOG_LEVEL` |

**Jak zachovat staré chování:**
- chcete-li *static* — nastavte explicitně `IP_MODE=static` + `STATIC_MAP` (static
  přesně zůstává).
- chcete-li *link-local* — `IP_MODE=linklocal` (LL ověřené na amd64 labu za
  podmínky namespace sysctl, **na RouterOS/ARM64 zatím ne**).
- chcete-li *DHCP s LL fallback* — `IP_MODE=dhcp DHCP_FALLBACK_LL=true`.

## Diagnostika (lokálně, v běžícím kontejneru)

```bash
docker logs <ctr>                       # ready/chyby/vše na stderr
docker exec <ctr> ip -o -4 addr show    # adresy na VLAN rozhraních
docker exec <ctr> ip -o link show       # VLAN childy + flagy
docker exec <ctr> cat /run/avahi-reflector/state.env  # stav supervizoru
docker exec <ctr> bash /healthcheck.sh; echo $?       # health (0/1)
```

## Staging / rollback nasazení

Doporučený postup nasazení nové verze bez ztráty staré:

1. buildni nový image pod **novým tagem** (nepřepisuj starý),
2. na routeru **ponechej starý root-dir/image** — vytvoř nový container s novým
   image a novým `root-dir` (`/container/add file=novy.tar root-dir=disk1/mdns-novy`),
3. při problému jen `/container/remove` nový a `/container/start` starý —
   starý image/root-dir zůstal nedotčený.

## Build

Lokální build (bez push). Pozor: `docker buildx build` s docker-container
driverem nic nenačte do lokálního store — pro lokální run/save použij `--load`
nebo `docker build` (docker driver):

```bash
docker build --platform linux/arm64 -t <image>:<tag> .
# nebo buildx s explicitním --load:
docker buildx build --platform linux/arm64 --load -t <image>:<tag> .
# nativní test build na amd64:
docker build --platform linux/amd64 -t <image>:<tag>-amd64 .
```

Viz `DevOps.md` pro komentovaný postup včetně **opt-in** publish kroku.
