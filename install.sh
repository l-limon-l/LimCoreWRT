#!/bin/sh
# Установщик LimCore для OpenWrt (в одном скрипте: APK / opkg / 23.05 legacy)
# https://github.com/l-limon-l/LimCoreWRT
#
# Вручную ставится только LuCI-приложение + ключ подписи, а ядро, ByeDPI и Zapret
# устанавливаются через собственный бэкенд приложения (core_mgmt.uc + rpcd-объект
# luci.limcore) — поэтому определение архитектуры, компактные сборки под малую
# флеш-память, проверка подписи и резерв через зеркало GitHub работают той же
# проверенной логикой, что и графический интерфейс.
#
# Установка (одной строкой — ввод читается из /dev/tty, пайп остаётся интерактивным):
#   wget -qO- https://raw.githubusercontent.com/l-limon-l/LimCoreWRT/main/install.sh | sh
# Либо в два шага:
#   wget -O /tmp/install.sh https://raw.githubusercontent.com/l-limon-l/LimCoreWRT/main/install.sh
#   sh /tmp/install.sh
#
# При заблокированном/замедленном GitHub можно указать зеркало:
#   GH_MIRROR=https://my.mirror sh install.sh
# (зеркало также пишется в uci, чтобы делегированные загрузки тоже его использовали).
# Внимание: `sh <(wget -O- ...)` на OpenWrt НЕ работает — в busybox ash нет
# process substitution; используйте форму с пайпом выше.

AUTO=0
for arg in "$@"; do
	case "$arg" in
		--auto|-y|--update|-u) AUTO=1 ;;
	esac
done
if [ -n "$AUTO_UPDATE" ] || [ -n "$NONINTERACTIVE" ]; then AUTO=1; fi

G='\033[0;32m'; R='\033[0;31m'; Y='\033[0;33m'; C='\033[0;36m'; N='\033[0m'
ok()   { echo -e "${G}$1${N}"; }
info() { echo -e "${C}$1${N}"; }
warn() { echo -e "${Y}$1${N}"; }
die()  { echo -e "${R}$1${N}"; exit 1; }
ask()  {
	if [ "$AUTO" = 1 ]; then
		REPLY=""
		return 0
	fi
	printf "${C}%s${N} " "$1"
	read -r REPLY </dev/tty 2>/dev/null || REPLY=""
}
is_yes() { case "$1" in y|Y|yes|YES|да|Да|д|Д) return 0;; *) return 1;; esac; }

# --- Разбор JSON (на устройстве нет jq): достать строковое поле / проверить result:true
jget()  { printf '%s\n' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
jtrue() { printf '%s'   "$1" | grep -qE "\"result\"[[:space:]]*:[[:space:]]*true"; }
jerr()  { printf '%s\n' "$1" | grep -qE "\"error\""; }
jfalse(){ printf '%s'   "$1" | grep -qE "\"$2\"[[:space:]]*:[[:space:]]*false"; }
jnum()  { printf '%s\n' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p" | head -1; }

# --- Загрузка «сначала GitHub, при сбое — зеркало» для первого хопа (app + ключ),
#     пока ещё нет собственного gh_fetch приложения. dl <url> <файл>
dl() {
	wget -qO "$2" --timeout=20 "$1" 2>/dev/null && [ -s "$2" ] && return 0
	if [ -n "$GH_MIRROR" ]; then
		m=$(echo "$1" | sed "s#https://github.com#${GH_MIRROR}#")
		wget -qO "$2" --timeout=20 "$m" 2>/dev/null && [ -s "$2" ] && return 0
	fi
	return 1
}
api() { wget -qO- --timeout=20 "$1" 2>/dev/null; }   # GitHub API (без зеркала)

echo
ok "===== Установщик LimCore ====="

# ---------------------------------------------------------------- 0. окружение
[ "$(id -u)" = 0 ] || die "Запустите от root."
[ -r /etc/openwrt_release ] || die "Это не OpenWrt (нет /etc/openwrt_release)."
. /etc/openwrt_release 2>/dev/null
ARCH="$DISTRIB_ARCH"; VER="$DISTRIB_RELEASE"
[ -n "$ARCH" ] || die "Не удалось определить архитектуру пакетов (DISTRIB_ARCH)."
if   command -v apk  >/dev/null 2>&1; then PM=apk;  EXT=apk
elif command -v opkg >/dev/null 2>&1; then PM=opkg; EXT=ipk
else die "Не найден поддерживаемый менеджер пакетов (apk/opkg)."; fi
case "$VER" in
	23.05*)              LEGACY=1 ;;
	24.10*|25.*|*SNAPSHOT*) LEGACY=0 ;;
	22.*|21.*|19.*)      die "OpenWrt $VER слишком старая — нужна 23.05 или новее." ;;
	*)                   LEGACY=0; warn "Непроверенная версия OpenWrt $VER — продолжаю." ;;
esac
SUFFIX="_all"; [ "$LEGACY" = 1 ] && SUFFIX="_all-legacy"
info "Версия: OpenWrt $VER  |  Архитектура: $ARCH  |  Менеджер пакетов: $PM  |  legacy=$LEGACY"

# ----------------------------------------------------------- 1. LuCI-приложение + ключ
ok "[1/5] Устанавливаю LuCI-приложение LimCore..."
if [ "$PM" = apk ]; then
	if [ ! -f /etc/apk/keys/LimCoreWRT.pub ]; then
		dl "https://github.com/l-limon-l/LimCoreWRT/releases/latest/download/LimCoreWRT.pub" /tmp/LimCoreWRT.pub \
			&& cp /tmp/LimCoreWRT.pub /etc/apk/keys/ && rm -f /tmp/LimCoreWRT.pub && ok "  ключ подписи добавлен в доверенные" \
			|| warn "  не удалось скачать ключ подписи — поставлю без проверки подписи"
	fi
fi
# ВАЖНО: берём именно /releases/latest, а не первый попавшийся ассет из /releases.
# Список релизов приходит НЕ в порядке версий (наблюдалось r8, r6, r10), поэтому
# `... /releases | head -1` мог поставить пользователю версию СТАРШЕ установленной —
# то есть «обновление» молча откатывало назад.
RELJSON=$(api 'https://api.github.com/repos/l-limon-l/LimCoreWRT/releases/latest')
APPURL=$(printf '%s\n' "$RELJSON" \
	| grep -o "https://github\.com/[^\"]*luci-app-limcore[^\"]*${SUFFIX}\.${EXT}" | head -1)
# Резерв: если /latest недоступен (нет релизов с пометкой latest), падаем на общий список.
[ -n "$APPURL" ] || APPURL=$(api 'https://api.github.com/repos/l-limon-l/LimCoreWRT/releases' \
	| grep -o "https://github\.com/[^\"]*luci-app-limcore[^\"]*${SUFFIX}\.${EXT}" | head -1)
[ -n "$APPURL" ] || die "Не нашёл пакет luci-app-limcore${SUFFIX}.${EXT} (GitHub заблокирован? попробуйте GH_MIRROR=...)."
dl "$APPURL" /tmp/app.$EXT || die "Не удалось скачать приложение (попробуйте GH_MIRROR=...)."
if [ "$PM" = apk ]; then
	# Сначала пробуем с проверкой подписи, и только потом без неё — но об этом СООБЩАЕМ.
	# Молчаливый откат означал, что сломанная или неподходящая подпись выглядит ровно как
	# успешная установка, и подписывание не даёт ничего, а никто этого не замечает.
	if apk add /tmp/app.$EXT 2>/dev/null; then
		:
	elif apk add --allow-untrusted /tmp/app.$EXT; then
		warn "  подпись не проверена — пакет установлен как недоверенный."
		warn "  (нет /etc/apk/keys/LimCoreWRT.pub, либо пакет не подписан, либо ключ не тот)"
	else
		die "apk add завершился ошибкой."
	fi
else
	opkg update >/dev/null 2>&1; opkg install /tmp/app.$EXT || die "opkg install завершился ошибкой."
fi
rm -f /tmp/app.$EXT
ok "  приложение установлено."

# Русский язык интерфейса (по умолчанию — да)
ask "  Установить пакет русского языка? [Y/n] (по умолчанию Y):"
case "$REPLY" in
	n|N|no|NO|нет|Нет|н|Н) ;;  # отказ — пропускаем
	*)
		info "  ставлю русский язык LuCI..."
		# базовый перевод интерфейса LuCI (из фида, best-effort)
		if [ "$PM" = apk ]; then apk add luci-i18n-base-ru >/dev/null 2>&1; else opkg install luci-i18n-base-ru >/dev/null 2>&1; fi
		# перевод самого приложения (из релиза limcore)
		# из того же релиза, что и приложение — иначе перевод разъедется с версией
		LURL=$(printf '%s\n' "$RELJSON" \
			| grep -o "https://github\.com/[^\"]*luci-i18n-limcore-ru[^\"]*\.${EXT}" | head -1)
		[ -n "$LURL" ] || LURL=$(api 'https://api.github.com/repos/l-limon-l/LimCoreWRT/releases' \
			| grep -o "https://github\.com/[^\"]*luci-i18n-limcore-ru[^\"]*\.${EXT}" | head -1)
		if [ -n "$LURL" ] && dl "$LURL" /tmp/i18n.$EXT; then
			if [ "$PM" = apk ]; then apk add /tmp/i18n.$EXT 2>/dev/null || apk add --allow-untrusted /tmp/i18n.$EXT; \
			else opkg install /tmp/i18n.$EXT; fi
		else warn "  перевод приложения не найден — пропускаю"; fi
		rm -f /tmp/i18n.$EXT
		uci set luci.main.lang=ru; uci commit luci
		ok "  русский язык установлен" ;;
esac

# Прописываем зеркало в бэкенд, чтобы делегированные загрузки тоже его использовали
if [ -n "$GH_MIRROR" ]; then uci set limcore.config.github_mirror="$GH_MIRROR"; uci commit limcore; fi

# Генерация постоянного HWID роутера на основе MAC-адреса
if [ -z "$(uci -q get limcore.config.hwid)" ]; then
	MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null || cat /sys/class/net/eth0/address 2>/dev/null || cat /etc/machine-id 2>/dev/null)
	[ -n "$MAC" ] || MAC="limcore-default-hwid-key"
	HEX=$(echo -n "$MAC" | md5sum | cut -d' ' -f1)
	H1=$(echo "$HEX" | cut -c1-8)
	H2=$(echo "$HEX" | cut -c9-12)
	H3=$(echo "$HEX" | cut -c14-16)
	H4=$(echo "$HEX" | cut -c18-20)
	H5=$(echo "$HEX" | cut -c21-32)
	GEN_HWID="${H1}-${H2}-4${H3}-a${H4}-${H5}"
	uci set limcore.config.hwid="$GEN_HWID"
	uci commit limcore
fi

# rpcd нужно перезапустить, чтобы появились ubus-методы приложения (установка ByeDPI/Zapret)
/etc/init.d/rpcd restart >/dev/null 2>&1; sleep 2
CM=/usr/share/limcore/scripts/core_mgmt.uc
[ -f "$CM" ] || die "core_mgmt.uc не найден после установки — прерываю."

# ------------------------------------------------------- 2. ядро прокси (опционально)

# Если ядро уже стоит и работает, шаг становится необязательным: сбой на этом месте
# (например, GitHub API временно не ответил) не должен проваливать всё обновление —
# приложение к этому моменту уже установлено. Раньше такой сбой давал «обновление
# завершилось с ошибкой» при полностью успешном апдейте.
CORE_PRESENT=0
[ -x /usr/bin/sing-box ] && CORE_PRESENT=1

# Спрашиваем так же, как про Zapret и ByeDPI. Ядро — самый крупный пакет установки
# (~75 МБ), и на устройстве с малым флешем его может быть просто некуда положить,
# тогда как обход DPI там работать будет. По умолчанию всё же «да»: для большинства
# нужен именно прокси, и молчаливый Enter не должен оставлять их без ядра.
DO_CORE=1
if [ "$AUTO" != 1 ]; then
	if [ "$CORE_PRESENT" = 1 ]; then
		ask "[2/5] Ядро sing-box уже установлено. Обновить его? [Y/n] (по умолчанию Y):"
	else
		ask "[2/5] Установить ядро sing-box-extended (~75 МБ)? Без него доступны только Zapret и ByeDPI. [Y/n] (по умолчанию Y):"
	fi
	case "$REPLY" in n|N|no|NO|нет|Нет|н|Н) DO_CORE=0 ;; esac
fi

if [ "$DO_CORE" = 1 ]; then
ok "  устанавливаю ядро sing-box-extended..."
core_fail() {
	if [ "$CORE_PRESENT" = 1 ]; then
		warn "  $1"
		warn "  ядро уже установлено ($(/usr/bin/sing-box version 2>/dev/null | head -1)) — пропускаю обновление ядра."
		return 1
	fi
	die "  $1"
}

CORE_OK=1
PREP=$(ucode "$CM" prepare_install)
if jerr "$PREP"; then
	core_fail "подготовка ядра не удалась: $(jget "$PREP" error)" || CORE_OK=0
fi
if [ "$CORE_OK" = 1 ]; then
DLURL=$(jget "$PREP" dl_url); TMP=$(jget "$PREP" tmp_path); PMG=$(jget "$PREP" pkg_manager)
DLSIZE=$(jnum "$PREP" dl_size)
if [ -z "$DLURL" ] || [ -z "$TMP" ] || [ -z "$PMG" ]; then
	core_fail "подготовка ядра не вернула данные для загрузки." || CORE_OK=0
fi
fi
if [ "$CORE_OK" = 1 ]; then
# Пустой размер не должен ронять установщик на арифметике: 0 = проверку пропускаем,
# загрузка всё равно состоится, просто без сверки длины.
[ -n "$DLSIZE" ] || DLSIZE=0

# Загрузка проверяется по размеру: оборванная закачка раньше проходила молча, apk
# регистрировал пакет, но 75-мегабайтный бинарник на диск не попадал.
if [ "$DLSIZE" -gt 0 ]; then
	info "  скачиваю ядро (~$((DLSIZE / 1048576)) МБ)..."
else
	warn "  размер пакета неизвестен — скачиваю без сверки длины."
fi
DLRES=$(ucode "$CM" download_pkg "$DLURL" "$TMP" "$DLSIZE")
if ! jtrue "$DLRES"; then
	core_fail "не удалось скачать ядро: $(jget "$DLRES" error)" || CORE_OK=0
fi
fi

if [ "$CORE_OK" = 1 ]; then
info "  устанавливаю пакет..."
INSRES=$(ucode "$CM" install_pkg "$TMP" "$PMG")
if ! jtrue "$INSRES"; then
	core_fail "установка ядра не удалась: $(jget "$INSRES" error)" || CORE_OK=0
fi
fi

if [ "$CORE_OK" = 1 ]; then
	jtrue "$(ucode "$CM" install_kmods "$PMG")" || warn "  не удалось поставить kmod — без kmod-nft-tproxy/kmod-tun прокси не будет маршрутизировать."
fi

# Финальная проверка по факту, а не по коду возврата установщика
[ -x /usr/bin/sing-box ] || die "  ядро отсутствует (/usr/bin/sing-box) — повторите установку."
[ "$CORE_OK" = 1 ] && ok "  ядро установлено: $(/usr/bin/sing-box version 2>/dev/null | head -1)"

else   # DO_CORE = 0
	if [ "$CORE_PRESENT" = 1 ]; then
		info "[2/5] Ядро не трогаю: $(/usr/bin/sing-box version 2>/dev/null | head -1)"
	else
		warn "[2/5] Ядро не устанавливаю — по вашему выбору."
		warn "  Учтите: служба LimCore пока не запускается без ядра, поэтому Zapret и ByeDPI"
		warn "  сами по себе тоже не поднимутся. Поставьте ядро позже на вкладке «Ядро и службы»."
		CORE_SKIPPED=1
	fi
fi

# --------------------------------------------------------------- 3. Zapret (опционально)
DO_ZAPRET=0
if [ "$AUTO" = 1 ]; then
	[ "$(uci -q get limcore.config.zapret_enabled)" = "1" ] || [ -x "/opt/zapret2/nfq2/nfqws2" ] && DO_ZAPRET=1
else
	ask "[3/5] Установить Zapret 2 (обход DPI на уровне пакетов — видео/QUIC, звонки)? [y/N]:"
	is_yes "$REPLY" && DO_ZAPRET=1
fi
if [ "$DO_ZAPRET" = 1 ]; then
	info "  ставлю модуль ядра NFQUEUE..."
	if [ "$PM" = apk ]; then apk add kmod-nft-queue >/dev/null 2>&1; else opkg install kmod-nft-queue >/dev/null 2>&1; fi
	ZP=$(ubus call luci.limcore zapret_prepare_install 2>/dev/null)
	if [ -z "$ZP" ] || jerr "$ZP"; then warn "  не удалось подготовить Zapret — пропускаю. ($(jget "$ZP" error))"
	else
		ZURL=$(jget "$ZP" dl_url); ZTMP=$(jget "$ZP" tmp_path); ZPMG=$(jget "$ZP" pkg_manager)
		if [ -n "$ZURL" ] && dl "$ZURL" "$ZTMP"; then
			RES=$(ubus call luci.limcore zapret_install_pkg "{\"tmp_path\":\"$ZTMP\",\"pkg_manager\":\"$ZPMG\"}" 2>/dev/null)
			if jtrue "$RES"; then
				ok "  Zapret установлен."
				ZST=$(ubus call luci.limcore zapret_status 2>/dev/null)
				if jfalse "$ZST" kmod_ok; then
					warn "  модуль NFQUEUE не загружен — Zapret не включаю (иначе сломается firewall). Включите вручную после kmod-nft-queue."
				else
					uci set limcore.config.zapret_enabled=1; uci commit limcore; ok "  Zapret включён."
				fi
			else warn "  установка Zapret не удалась."; fi
		else warn "  не удалось скачать Zapret — пропускаю."; fi
	fi
fi

# --------------------------------------------------------------- 4. ByeDPI (опционально)
DO_BYEDPI=0
if [ "$AUTO" = 1 ]; then
	[ "$(uci -q get limcore.config.byedpi_enabled)" = "1" ] || [ -x "/usr/bin/ciadpi" ] && DO_BYEDPI=1
else
	ask "[4/5] Установить ByeDPI (обход DPI на уровне SOCKS, нужен curl)? [y/N]:"
	is_yes "$REPLY" && DO_BYEDPI=1
fi
if [ "$DO_BYEDPI" = 1 ]; then
	info "  ставлю curl (его использует тестер стратегий ByeDPI)..."
	if [ "$PM" = apk ]; then apk add curl >/dev/null 2>&1; else opkg install curl >/dev/null 2>&1; fi
	BP=$(ubus call luci.limcore byedpi_prepare_install 2>/dev/null)
	if [ -z "$BP" ] || jerr "$BP"; then warn "  не удалось подготовить ByeDPI — пропускаю. ($(jget "$BP" error))"
	else
		BURL=$(jget "$BP" dl_url); BTMP=$(jget "$BP" tmp_path); BPMG=$(jget "$BP" pkg_manager)
		if [ -n "$BURL" ] && dl "$BURL" "$BTMP"; then
			RES=$(ubus call luci.limcore byedpi_install_pkg "{\"tmp_path\":\"$BTMP\",\"pkg_manager\":\"$BPMG\"}" 2>/dev/null)
			if jtrue "$RES"; then
				ok "  ByeDPI установлен."
				uci set limcore.config.byedpi_enabled=1; uci commit limcore; ok "  ByeDPI включён."
			else warn "  установка ByeDPI не удалась."; fi
		else warn "  не удалось скачать ByeDPI — пропускаю."; fi
	fi
fi

# ------------------------------------------------- 5. режим маршрутизации (пресет)
ask "[5/5] Настроить режим «Россия — раздельное туннелирование» (Re:filter через основной сервер)? [Д/н] (по умолчанию да):"
case "$REPLY" in
	n|N|no|NO|нет|Нет|н|Н) ;;  # отказ — оставляем как есть
	*)
		CURMODE=$(uci -q get limcore.config.routing_mode)
		if [ -z "$CURMODE" ]; then
			uci set limcore.config.routing_mode=proxy_banned_ru
			uci set limcore.config.proxy_calls=1
			uci set limcore.config.no_proxy_torrents=1
			uci set limcore.config.ipv6_support=0
			uci commit limcore
			CURMODE=proxy_banned_ru
		fi
		# Re:filter через основной пул — только если режим РФ и правил ещё нет
		if [ "$CURMODE" = proxy_banned_ru ] && ! uci show limcore 2>/dev/null | grep -q "=proxy_ru_rule$"; then
			SEC=$(uci add limcore proxy_ru_rule)
			uci set "limcore.$SEC.source=refilter"
			uci set "limcore.$SEC.node=main-out"
			uci set "limcore.$SEC.enabled=1"
			uci commit limcore
			ok "  режим настроен: Re:filter через основной сервер"
		else
			info "  режим/правила уже заданы — не меняю"
		fi ;;
esac

# ------------------------------------------------------------------- 6. финал
/etc/init.d/limcore enable  >/dev/null 2>&1

# Без ядра start_service выходит раньше, чем поднимет хоть один экземпляр, поэтому
# запускать нечего — а «Готово» со ссылкой на страницу выглядело бы так, будто всё
# работает. Пусть последнее, что видит человек, совпадает с тем, что на устройстве.
if [ "$CORE_SKIPPED" = 1 ]; then
	echo
	warn "===== Установка завершена, служба НЕ запущена ====="
	warn "Ядро не установлено, а без него не стартуют и Zapret с ByeDPI."
	info "Поставьте ядро в интерфейсе: LimCore → «Ядро и службы» → «Установить ядро»,"
	info "либо запустите установщик заново и ответьте «y» на вопрос про ядро."
else
	/etc/init.d/limcore start >/dev/null 2>&1
fi

# LAN-адрес роутера для прямой ссылки на страницу LuCI (обрезаем /маску на 25.12+)
LANIP=$(uci -q get network.lan.ipaddr | cut -d/ -f1)
[ -n "$LANIP" ] || LANIP=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's#.*inet \([0-9.]*\).*#\1#p' | head -1)
[ -n "$LANIP" ] || LANIP="192.168.1.1"

echo
[ "$CORE_SKIPPED" = 1 ] || ok "===== Готово ====="
info "Откройте LimCore в браузере:"
URL="http://$LANIP/cgi-bin/luci/admin/services/limcore"
# OSC 8: кликабельная ссылка в поддерживающих терминалах; в остальных просто виден URL
printf '\033[0;36m  \033]8;;%s\033\\%s\033]8;;\033\\\033[0m\n' "$URL" "$URL"
