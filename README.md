# TT

یک مدیر تعاملی واحد برای راه‌اندازی TT بین دو VPS:

- سرور خارج: نصب Endpoint، بررسی دامنه و Full Chain/Private Key، بررسی پورت 443، ساخت systemd و خروجی TOML
- سرور ایران: انتخاب فایل TOML، نصب Client، انتخاب SOCKS5 یا TUN، ساخت systemd و تست اتصال
- مدیریت: وضعیت، لاگ، Restart، بازپیکربندی، به‌روزرسانی هسته و حذف همراه با بکاپ

این پروژه از نصب‌کننده‌های رسمی استفاده می‌کند و فایل‌های باینری را در مخزن نگه نمی‌دارد.

## نکته مهم درباره احراز هویت

دو احراز هویت مستقل وجود دارد:

1. `Endpoint credentials`: روی سرور خارج ساخته و داخل فایل Export کلاینت قرار می‌گیرد.
2. `SOCKS credentials`: روی سرور ایران ساخته و فقط از مصرف‌کننده محلی مانند 3x-ui محافظت می‌کند.

فایل Export سرور خارج نمی‌تواند پورت یا رمز SOCKS سرور ایران را تعیین کند. Listener محلی در `trusttunnel_client.toml` تعریف می‌شود.

## پیش‌نیاز

- Debian یا Ubuntu دارای systemd
- معماری x86_64 یا ARM64
- اجرای اسکریپت با کاربر root
- برای Endpoint، دامنه مستقیم و بدون Cloudflare Proxy
- Full Chain و Private Key معتبر
- آزاد بودن TCP و UDP پورت 443 روی سرور خارج

## نصب و اجرا

پس از انتشار فایل در GitHub:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Colaabi75/tt/main/trusttunnel-manager.sh)
```

اسکریپت یک فرمان دائمی هم نصب می‌کند:

```bash
trusttunnel-manager
```

## ترتیب استفاده

### 1. سرور خارج

Manager را اجرا و گزینه «خارج» را انتخاب کنید. اطلاعات زیر پرسیده می‌شود:

- دامنه Endpoint
- مسیر کامل Full Chain
- مسیر کامل Private Key
- نام کاربری و رمز Endpoint

پس از موفقیت، این فایل ساخته می‌شود:

```text
/root/trusttunnel-client-export.toml
```

فایل محرمانه است. آن را دانلود و به سرور ایران منتقل کنید؛ در GitHub یا چت عمومی قرار ندهید.

### 2. سرور ایران

Manager را اجرا و گزینه «ایران» را انتخاب کنید. مسیر پیش‌فرض جست‌وجوی فایل `/root` است. اگر فقط یک TOML پیدا شود، با Enter همان فایل انتخاب می‌شود.

برای استفاده با 3x-ui حالت SOCKS5 پیشنهاد می‌شود. SOCKS روی `127.0.0.1` قرار می‌گیرد و Route یا DNS کل سرور را عوض نمی‌کند.

### 3. تنظیم Outbound در 3x-ui

- Protocol: `SOCKS`
- Address: `127.0.0.1`
- Port: پورتی که در Manager انتخاب کرده‌اید
- Username/Password: اطلاعات SOCKS واردشده در سرور ایران

ساخت Outbound به‌تنهایی کافی نیست؛ Routing Rule مربوط به Inbound موردنظر باید به Tag این Outbound اشاره کند.

## انتشار در GitHub

1. در GitHub یک Repository جدید بسازید، مثلاً `trusttunnel-manager`.
2. فایل `trusttunnel-manager.sh` را در ریشه مخزن Upload کنید.
3. فایل `README.md` را نیز Upload کنید.
4. شاخه را `main` و Repository را Public قرار دهید تا Raw URL بدون احراز هویت قابل دریافت باشد.
5. به‌جای `USERNAME/REPOSITORY` در دستور نصب، نام حساب و مخزن خودتان را بگذارید.

قبل از انتشار، بررسی محلی:

```bash
bash -n trusttunnel-manager.sh
shellcheck trusttunnel-manager.sh
bash tests/test_helpers.sh
```

## مسیرهای مهم

| مورد | مسیر |
|---|---|
| فرمان Manager | `/usr/local/bin/trusttunnel-manager` |
| وضعیت Manager | `/etc/trusttunnel-manager/state.env` |
| بکاپ‌ها | `/etc/trusttunnel-manager/backups/` |
| Endpoint | `/opt/trusttunnel/` |
| Client | `/opt/trusttunnel_client/` |
| خروجی انتقالی | `/root/trusttunnel-client-export.toml` |

## امنیت

- فایل Export شامل رمز Endpoint است و باید با دسترسی `0600` نگهداری شود.
- SOCKS به‌صورت پیش‌فرض فقط روی `127.0.0.1` گوش می‌دهد و از اینترنت قابل دسترسی نیست.
- Manager برای رمزهای Endpoint و SOCKS حداقل ۱۲ کاراکتر درخواست می‌کند.
- اسکریپت Xray/3x-ui را خودکار Stop نمی‌کند؛ اگر 443 اشغال باشد، برنامه اشغال‌کننده را نشان می‌دهد و متوقف می‌شود.
- حذف TrustTunnel به گواهی و کلیدهایی که خارج از `/opt` هستند دست نمی‌زند.
