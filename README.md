# AURA

Мессенджер со сквозным шифрованием для Web, Android и iOS на Flutter.

План работ: [ROADMAP.md](ROADMAP.md)

## Сервер

Сервер раздаёт Web-приложение и API на одном порту. Нужен только Docker.

```sh
git clone https://github.com/OleksandrYech/aura && cd aura
docker compose up -d --build
```

Откройте `http://<IP сервера>:8080` в браузере. Мобильные приложения всегда подключаются к `https://web.aura-msg.space` через туннель (ниже); адрес задан в `AuraClient.server` (`app/lib/client.dart`).

Обновление: `git pull && docker compose up -d --build`.

Сообщения шифруются на устройствах (Signal Protocol), сервер хранит только шифротекст до доставки. У каждого устройства свои ключи, поэтому вход на новом устройстве не переносит туда старую переписку.

База (`aura.db`) лежит в томе `aura-data`. Резервная копия:

```sh
docker compose cp aura:/data/aura.db ./aura-backup.db
```

### Доступ из интернета через Cloudflare Tunnel

1. В [Cloudflare Zero Trust](https://one.dash.cloudflare.com/) откройте Networks → Tunnels → Create a tunnel (тип Cloudflared), назовите его `aura`.
2. Скопируйте токен туннеля и положите его в файл `.env` рядом с `docker-compose.yml`:
   ```
   TUNNEL_TOKEN=eyJ...
   ```
3. В настройках туннеля добавьте Public Hostname: ваш домен (например `aura.example.com`), сервис `http://aura:8080`.
4. Запустите вместе с туннелем:
   ```sh
   docker compose --profile tunnel up -d --build
   ```

Cloudflare сам выдаёт HTTPS-сертификат, открывать порты на роутере не нужно. После этого строку `ports` в `docker-compose.yml` можно убрать, чтобы сервер был доступен только через туннель.

## Android: обновления без переустановки

CI подписывает APK постоянным ключом и после каждого мёржа в `main` выкладывает его в [Releases](../../releases). Приложение [Obtainium](https://github.com/ImranR98/Obtainium) на телефоне следит за релизами и ставит обновление поверх, ключи шифрования и переписка сохраняются.

Ключ создаётся один раз (на любой машине с Docker), пароль придумайте свой:

```sh
docker run --rm --user "$(id -u):$(id -g)" -v "$PWD":/k -w /k eclipse-temurin:21-jre keytool -genkeypair -keystore aura.jks -alias aura \
  -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=AURA" -storepass 'ПАРОЛЬ' -keypass 'ПАРОЛЬ'
base64 -w0 aura.jks > aura.jks.b64
```

В репозитории Settings → Secrets and variables → Actions добавьте секреты `ANDROID_KEYSTORE_BASE64` (содержимое `aura.jks.b64`) и `ANDROID_KEYSTORE_PASSWORD`. Файл `aura.jks` сохраните в надёжном месте: без него обновления перестанут ставиться поверх.

## Разработка

Нужен [Flutter](https://docs.flutter.dev/get-started/install) 3.47.

```sh
# Web: собрать приложение и раздать его сервером на http://localhost:8080
(cd app && flutter build web --no-web-resources-cdn)
(cd server && AURA_WEB=../app/build/web dart run bin/main.dart)
```

Мобильные приложения подключаются к адресу из `AuraClient.server` в `app/lib/client.dart`;
для отладки с локальным сервером замените его (с эмулятора Android компьютер доступен как `http://10.0.2.2:8080`).

```sh
cd app
flutter run -d android    # Android (эмулятор или телефон)
flutter run -d ios        # iOS (только на macOS)
```

Готовые сборки Web и Android лежат в артефактах GitHub Actions каждого запуска.
