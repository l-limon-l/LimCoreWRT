# ⚡ LimCore

[🇬🇧 English](#-english) | [🇷🇺 Русский](#-русский)

---

<a id="-english"></a>
## 🇬🇧 English

**LimCore** is a modern proxy platform for OpenWrt created by **l_limon_l**. Built on top of [sing-box-extended](https://github.com/shtorm-7/sing-box-extended).

### 🚀 Features
- **sing-box-extended Core**: AmneziaWG, WARP and the widest protocol set, installed and updated from the UI with storage checks and download verification.
- **Dual Anti-DPI Engines**: Built-in **ByeDPI** ([hufrea/byedpi](https://github.com/hufrea/byedpi)) and **Zapret 2** ([bol-van/zapret2](https://github.com/bol-van/zapret2)) for un-throttling sites (YouTube, Discord, etc.) without a VPN subscription.
- **Smart URLTest Routing**: Automatic failover and routing through the fastest node based on real-time latency measurements.
- **Russia Routing Rules**: One-click RU Proxy Rules (Russia Inside, Re:Filter) for targeted domain/IP routing.
- **Subscription Support**: Import nodes from VLESS, VMess, Trojan, Shadowsocks, WireGuard, AmneziaWG, and Xray/Hiddify subscriptions.
- **Integrated Diagnostics**: Built-in LuCI tools for port testing, core status inspection, log viewing, and one-click diagnostic reporting.
- **Per-Device Internet Pause**: Cut or restore internet access for any device on the network, and give it a name of your own. Ported from **Device Control** ([Yany1944/Device-Control](https://github.com/Yany1944/Device-Control)): its rules hook prerouting ahead of the proxy, so a paused device is actually blocked instead of slipping through the transparent proxy the way an ordinary firewall rule does.

### 📦 Installation & Usage

Run this command over SSH on your OpenWrt router (supports APK, OPKG, and 23.05 legacy):

```bash
wget -qO- https://raw.githubusercontent.com/l-limon-l/LimCoreWRT/main/install.sh | sh
```

### 💬 Contact
- **Telegram**: [t.me/i_limon_i](https://t.me/i_limon_i)

---

<a id="-русский"></a>
## 🇷🇺 Русский

**LimCore** — современная прокси-платформа для OpenWrt от автора **l_limon_l**. Работает на базе [sing-box-extended](https://github.com/shtorm-7/sing-box-extended).

### 🚀 Возможности
- **Ядро sing-box-extended**: AmneziaWG, WARP и самый широкий набор протоколов; установка и обновление из интерфейса с проверкой места и сверкой загрузки.
- **Два встроенных движка обхода DPI**: **ByeDPI** ([hufrea/byedpi](https://github.com/hufrea/byedpi)) и **Zapret 2** ([bol-van/zapret2](https://github.com/bol-van/zapret2)) для разблокировки сайтов (YouTube, Discord и др.) без VPN.
- **Автовыбор URLTest**: Автоматическое переключение на самый быстрый узел по задержке в реальном времени.
- **Правила для РФ**: Готовые списки маршрутизации (Russia Inside, Re:Filter) для выборочной проксификации.
- **Поддержка подписок**: Импорт VLESS, VMess, Trojan, Shadowsocks, WireGuard, AmneziaWG и подписок Hiddify/Xray.
- **Диагностика и управление**: Встроенный контроль портов, логирование, отчёты и управление ядрами из веб-интерфейса LuCI.
- **Пауза интернета по устройствам**: Отключение и возврат интернета любому устройству в сети, со своими названиями. Перенесено из **Device Control** ([Yany1944/Device-Control](https://github.com/Yany1944/Device-Control)): правила вешаются на prerouting раньше прокси, поэтому остановленное устройство действительно блокируется, а не проскакивает через прозрачный прокси, как это происходит с обычным правилом межсетевого экрана.

### 📦 Установка и использование

Выполните команду по SSH на вашем роутере OpenWrt (поддерживает APK, OPKG и 23.05 legacy):

```bash
wget -qO- https://raw.githubusercontent.com/l-limon-l/LimCoreWRT/main/install.sh | sh
```

### 💬 Связь
- **Telegram**: [t.me/i_limon_i](https://t.me/i_limon_i)
