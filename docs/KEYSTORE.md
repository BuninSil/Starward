# Ключ подписи APK — создаётся ОДИН раз

Android ставит обновление поверх старой версии, только если оба APK подписаны **одним и тем же ключом**.
Поэтому ключ создаётся один раз, хранится в GitHub Secrets и больше никогда не меняется.
CI сборки ключ никогда не генерирует: нет секретов — сборка `main` падает.

Всё ниже делается с телефона в браузере (github.com, включи «Версия для ПК» в меню браузера — в мобильной версии части настроек нет).

## Вариант А (рекомендуется): через разовый workflow

### 1. Придумай пароль и alias и положи их в Secrets

`Settings → Secrets and variables → Actions → New repository secret`:

| Имя | Значение |
|---|---|
| `ANDROID_KEYSTORE_PASSWORD` | длинный пароль, **минимум 12 символов**, только латиница и цифры (без кавычек, `$`, пробелов) |
| `ANDROID_KEY_ALIAS` | например `starward` |

**Пароль сразу сохрани в менеджер паролей** — без него ключ из бэкапа не восстановить.

### 2. Создай временный токен, которым workflow запишет ключ в Secrets

1. Аватар → `Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token`.
2. Name: `starward-keystore-once`, Expiration: **1 день**.
3. Repository access: **Only select repositories** → `BuninSil/Starward`.
4. Permissions → Repository permissions → **Secrets: Read and write** (Metadata: Read выставится сам). Больше ничего.
5. Generate → скопируй токен.
6. В репозитории: `Settings → Secrets and variables → Actions → New repository secret`, имя `SECRETS_ADMIN_TOKEN`, значение — токен.

### 3. Запусти workflow

`Actions → Create signing keystore (one-time) → Run workflow`, в поле `confirm` впиши `CREATE` → Run.

Workflow:
- создаст ключ RSA-4096 на 100 лет;
- сохранит его в секрет `ANDROID_KEYSTORE_BASE64`;
- выложит **зашифрованный** бэкап ключа артефактом `keystore-backup-encrypted` (живёт 7 дней);
- откажется работать, если `ANDROID_KEYSTORE_BASE64` уже существует — то есть случайно затереть ключ нельзя.

### 4. Прибери за собой

1. Открой завершившийся запуск workflow → внизу `Artifacts` → скачай `keystore-backup-encrypted` и положи в Google Drive / облако. Это твой бэкап: секреты GitHub прочитать обратно нельзя.
2. Удали секрет `SECRETS_ADMIN_TOKEN` и сам токен в `Developer settings` (или просто дождись, пока он протухнет через день).

Готово. Теперь каждый пуш в `main` даёт подписанный APK и релиз.

Восстановить ключ из бэкапа (если когда-нибудь понадобится, например в Termux):
```
openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 -in release.keystore.enc -out release.keystore
```

## Вариант Б: через Termux на телефоне

Если не хочешь давать workflow токен:

```
pkg install openjdk-17 termux-api
keytool -genkeypair -v -keystore starward.keystore -storetype PKCS12 \
  -alias starward -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=Starward"
base64 -w0 starward.keystore | termux-clipboard-set
```
(для `termux-clipboard-set` нужно приложение Termux:API)

Дальше в Secrets: `ANDROID_KEYSTORE_BASE64` = вставить из буфера, `ANDROID_KEYSTORE_PASSWORD` = пароль, который вводил, `ANDROID_KEY_ALIAS` = `starward`.
Файл `starward.keystore` скопируй в облако как бэкап.

## Проверка

В описании каждого релиза есть строка `Подпись SHA-256: …`. Она должна быть **одинаковой** во всех релизах.
Если когда-нибудь поменяется — обновление поверх не встанет, это сигнал, что ключ подменился.
