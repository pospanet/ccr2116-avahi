# ============================================================================
# Avahi mDNS reflektor - KOMENTOVANÁ ŠABLONA pro RouterOS v7.x container
# ----------------------------------------------------------------------------
# !!! NESPOUŠTĚJTE CELÉ - jen k ručnímu přezkoumání a postupnému kopírování !!!
#
# Syntax odpovídá oficiální dokumentaci MikroTik (RouterOS 7.26):
#   Containers:       https://manual.mikrotik.com/docs/containers/
#   VETH:             https://manual.mikrotik.com/docs/containers/veth
#   /container CLI:   https://manual.mikrotik.com/docs/cli-reference/container/
#   /container/envs:  https://manual.mikrotik.com/docs/cli-reference/container/envs/
# Starší verze ROS mají odlišnou syntax/aliasy - OVĚŘTE proti své verzi.
#
# CCR2116 = linux/arm64. Názvy/IP jsou PRIVÁTNÍ PLACEHOLDERY.
#
# Předpoklady, které šablona NEŘEŠÍ (udělat ručně předem dle své sítě):
#   * nainstalovaný balíček "container" + device-mode container=yes
#     (vyžaduje fyzický přístup - NEPŘIDÁVÁME device-mode změnu ani reboot)
#   * existující VLAN trunk na routeru (bridge + VLAN filtering)
#   * externí disk (disk1) pro image a root-dir
# Šablona NEMĚNÍ firewall, NEvypíná filtrování, NEmění device-mode a
# NErestartuje router. Vše je zakomentované.
# ============================================================================


# ----------------------------------------------------------------------------
# KROK 1: veth + env (před /container/add - jsou to jeho závislosti)
# ----------------------------------------------------------------------------
# RouterOS kontejner používá /interface/veth jako svůj "uplink". POZOR: dle
# oficiálních docs (containers/veth) se v kontejneru rozhraní jmenuje
# "the veth's name and the container-mac-address" - tedy uvnitř se objeví pod
# názvem VETH (např. veth-mdns), NE eth0. Naše proměnná BASE_IF MUSÍ odpovídat
# skutečnému jménu - ověřte po startu: /container/shell ... ip -o link show
# (na starších ROS se jména mohou lišit - nepředpokládejte eth0).
#
#   /interface/veth/add name=veth-mdns
#
# Napojení veth na tagovaný trunk (ZÁVISLÉ NA VAŠÍ BRIDGE/VLAN TOPOLOGII):
# veth musí být členem bridge nesoucí tagovaný trunk. V /interface/bridge/vlan
# přidejte veth-mdns jako TAGOVANÝ člen JEN pro povolené VLAN (10,20) - žádné
# implicitní untagged discovery, žádná data mimo tyto VLAN.
#   /interface/bridge/port/add bridge=<VAS_TRUNK_BRIDGE> interface=veth-mdns
#   /interface/bridge/vlan add bridge=<VAS_TRUNK_BRIDGE> \
#       tagged=<trunk-ports>,veth-mdns vlan-ids=10,20
# !!! VLAN-IDS, BRIDGE A TAGOVANÉ PORTY JSOU SPECIFICKÉ PRO VAŠI SÍŤ !!!
# (HW offload / switch chip / sfp se liší - ověřte vlastní docs. Chybné
#  tagování = kontejner VLANy neuvidí.)
#
# Env proměnné (current syntax: envlists= ve /container, list= ve /envs):
#   /container/envs/add list=AVAHI key=VLAN_LIST       value="10,20"
#   /container/envs/add list=AVAHI key=BASE_IF         value="veth-mdns"
#   /container/envs/add list=AVAHI key=IP_MODE         value="static"
#   /container/envs/add list=AVAHI key=STATIC_MAP      value="10:192.168.10.250/24,20:192.168.20.250/24"
#   /container/envs/add list=AVAHI key=LOG_LEVEL       value="info"
#   /container/envs/add list=AVAHI key=STARTUP_TIMEOUT value="60"
# (volitelné) /container/envs/add list=AVAHI key=REFLECT_FILTERS value="_ipp._tcp.local,_airplay._tcp.local"
#
# !!! IP ADRESY V STATIC_MAP JSOU PLACEHOLDERY - dosaďte skutečné !!!
# STATIC_MAP musí mít přesně jednu položku VID:IPv4/prefix pro KAŽDÉ vid.
# Composed jméno "veth-mdns.4094" = 14 znaků <= 15 OK.
# Ve 'static' je 169.254/16 zakázáno. IP_MODE=dhcp/linklocal je na NATIVE
# amd64 labu ověřený, ale na RouterOS NENÍ - RouterOS nepodporuje Docker
# --sysctl flag jako container property, takže promote_secondaries prerekvizita
# tu pravděpodobně nedá nastavit. Používejte 'static', dokud není validováno.


# ----------------------------------------------------------------------------
# KROK 2: image + container (až po veth + env)
# ----------------------------------------------------------------------------
# a) lokálně buildnout arm64 image (viz DevOps.md), export a upload:
#      docker save ccr2116-avahi:<tag>-arm64 -o avahi.tar
#      upload avahi.tar na router (do disk1/)
# b) přidat kontejner (file= import z tar; envlists= plural per CLI ref):
#   /container/add file=disk1/avahi.tar name=mdns-reflector interface=veth-mdns \
#       root-dir=disk1/mdns-reflector logging=yes start-on-boot=yes \
#       envlists=AVAHI
# Pozn.: 'interface=' přiřazuje veth. Po přidání se image extrahuje; spustí se
#        až /container/start. 'logging=yes' posílá výstup do /log.


# ----------------------------------------------------------------------------
# KROK 3: start + ověření
# ----------------------------------------------------------------------------
#   /container/start mdns-reflector
#   /log/print where topics~"container"
#   /container/print detail
# Očekávané logy: "created VLAN veth-mdns.10..", "static: veth-mdns.10 ->
# <addr>", "Server startup complete.", "ready: avahi initialized ...".
# Ověřte BASE_IF: /container/shell mdns-reflector cmd="ip -o link show"


# ----------------------------------------------------------------------------
# KROK 4: healthcheck (RouterOS 7.23+)
# ----------------------------------------------------------------------------
# RouterOS má VLASTNÍ healthcheck (nezávislý na Dockerfile HEALTHCHECK; import
# defaultů ověřte přes /container/print detail - 'default-healthcheck-*' jsou
# read-only pole). Explicitně nastavte cmd na náš skript:
#   /container/set mdns-reflector \
#       healthcheck-cmd="/bin/bash /healthcheck.sh" \
#       healthcheck-interval=00:00:30 healthcheck-timeout=00:00:08 \
#       healthcheck-start-period=00:01:15 healthcheck-retries=3
#
# healthcheck = "rozhraní nahoře + očekávaná adresa + avahi žije + ack",
# NIKOLIV důkaz end-to-end odrážení. Funkci ověřte reálným mDNS dotazem mezi
# dvěma hosty na různých VLAN.
# (volitelné, vyžaduje 7.x podporu - NEzakládat bez ověření verze: restart-
#  policy / stop-on-unhealthy pro automatický restart - nepředpokládejte je.)


# ----------------------------------------------------------------------------
# KROK 5: odstranění (cleanup)
# ----------------------------------------------------------------------------
#   /container/stop  mdns-reflector
#   /container/remove mdns-reflector
#   /interface/bridge/port/remove [find interface=veth-mdns]
#   /interface/veth/remove veth-mdns
#   # envs + bridge/vlan položky, které jste přidali, odstraňte ručně.
#
# ============================================================================
# BEZPEČNOSTNÍ SHRNUTÍ
#  - Reflektor odráží mDNS mezi VŠEMI povolenými VLAN - není to firewall.
#    REFLECT_FILTERS omezují služby, ne izolují hostitele (holý A záznam
#    nesplňující filtr se stejně přepošle).
#  - Neprovozujte dva reflektory mezi stejnými VLAN (ping-pong).
#  - Proces v kontejneru startuje jako root (bootstrap + NET_ADMIN na linkové
#    změny); avahi-daemon se sám zbaví práv (drop root+chroot), dhcpcd má
#    privsep. Nepřidávejte /container/set user=<nonroot> - rozbilo by
#    bootstrap; schopnosti minimalizujte až dle ověřených ROS cap-flagů.
#  - Kontejner = důvěryhodnost vašeho image; RouterOS docs upozorňují, že
#    3rd-party image je útočná plocha - držte image minimální.
# ============================================================================
