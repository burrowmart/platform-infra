# Інструкція 1. Локальний деплой у Kubernetes

Перший з двох кроків. Тут ти піднімаєш Kubernetes на власному ноутбуці й
розгортаєш у ньому сервіси. **Нічого не коштує, акаунт AWS не потрібен.**

Коли це запрацює — переходь до
[AWS-GETTING-STARTED.md](AWS-GETTING-STARTED.md) (акаунт AWS і кластер), а
далі до [AWS-DEPLOYMENT.md](AWS-DEPLOYMENT.md) (решта платформи).

Час: перший раз ~1.5 години, з яких більшість — складання Docker-образів.

---

## Навіщо спершу локально

Той самий деплой в AWS складається з двох незалежних частин: **Kubernetes**
(поди, сервіси, Helm) і **хмара** (IAM, мережа, секрети, тунель). Якщо робити
все одразу, то на першій же помилці незрозуміло, у чому річ — у чарті чи в
правах IAM.

Локальний прогін прибирає другу половину. Залишається чистий Kubernetes: тут
ти навчишся читати `kubectl get pods`, розуміти `CrashLoopBackOff` і дивитись
логи. В AWS ці навички вже будуть, і там залишиться розбиратись тільки з
хмарою.

---

## Що вимкнено локально і чому

Той самий Helm-чарт розгортається і сюди, і в AWS. Різниця тільки у файлі
значень [`demo/values-local.yaml`](../demo/values-local.yaml):

| Вимкнено | Чому | Наслідок |
|---|---|---|
| `externalSecrets` | Оператора External Secrets і його CRD немає на ноутбуці | Секрети беруться зі звичайного `Secret`, який ти створиш руками |
| — | **Envoy PEP + OPA лишаються увімкненими** | авторизація працює по-справжньому, див. крок 5 |
| — | **Ingress лишається увімкненим**, із тим самим класом `nginx-internal` | доступ через один порт із заголовком `Host`, див. крок 9 |
| `irsaRoleArn` | Немає AWS | Под не отримує AWS-токен, він тут і не потрібен |
| `autoscaling`, `podDisruptionBudget` | Одна нода | На одній ноді вони й так безглузді |
| `AUTH_DISABLED=true` | Немає Cognito | Сам сервіс не перевіряє JWT — але Envoy+OPA перед ним перевіряють підпис токена й роль |

Конфігурація для AWS від цього не змінилась — усе вимикається зовнішнім
файлом, самі чарти залишились ті самі.

**Що НЕ вимикається — авторизація і маршрутизація.** Envoy-сайдкар і OPA працюють локально
так само, як у хмарі: той самий `opa-policies/bundle`, та сама перевірка
підпису JWT, ті самі рішення allow/deny. Це найцікавіша частина архітектури,
і вимикати її було б шкода. Локальний OPA простіший за хмарний лише тим, що
bundle приходить файлом, а не з S3, і немає OPAL — сама політика та сама.

Ingress теж справжній: той самий `ingress-nginx`, той самий `IngressClass`
`nginx-internal`, ті самі анотації. Локально не вистачає лише Cloudflare
Tunnel перед ним — у хмарі `cloudflared` дзвонить назовні й передає трафік
на цей контролер, а тут ти стукаєш у нього напряму.

---

## Крок 1. Перевірити інструменти

```bash
docker version --format '{{.Server.Version}}'   # Docker має бути ЗАПУЩЕНИЙ
kind version
kubectl version --client
helm version --short
```

Усі чотири мають відповісти. Якщо `docker` мовчить — запусти Docker Desktop і
дочекайся, поки іконка перестане блимати.

**Пам'ять Docker.** Ми запустимо 12 сервісів плюс три бази. Відкрий Docker
Desktop → Settings → Resources і переконайся, що виділено щонайменше **8 GB**.
Менше — поди почнуть падати з `OOMKilled`, і це виглядатиме як помилка в коді.

---

## Крок 2. Створити кластер

```bash
kind create cluster --name archtenet --config platform-infra/demo/kind-config.yaml
```

Конфіг важливий: він відкриває порт 8081 на твоєму ноутбуці в кластер і
позначає ноду міткою `ingress-ready`. **Додати це до вже створеного кластера
не можна** — якщо кластер у тебе вже є, спершу `kind delete cluster --name
archtenet`.

`kind` = «Kubernetes in Docker»: він запускає ноду кластера як звичайний
Docker-контейнер. Займає ~1 хвилину.

Перевірка:

```bash
kubectl config current-context     # має бути kind-archtenet
kubectl get nodes                  # одна нода, STATUS Ready
```

> `kubectl` вміє працювати з багатьма кластерами й перемикається між ними
> «контекстами». `kind create` перемкнув тебе на новий кластер автоматично.
> Далі, коли з'явиться ще й AWS-кластер, перемикатись між ними будеш командою
> `kubectl config use-context`.

---

## Крок 3. Підняти Redis і RabbitMQ

```bash
cd /Users/ajjya/Projects/archtenet/backend
kubectl apply -f platform-infra/demo/data-namespace.yaml
```

Створює namespace `data` і в ньому Redis та RabbitMQ. MongoDB тут немає
навмисно — вона в тебе вже є в Atlas, і наступний крок про неї.

Цей файл заодно вмикає в RabbitMQ вбудований плагін `rabbitmq_prometheus` —
на нього спирається спостережуваність (`k8s/observability/`), тож не дивуйся
двом зайвим ConfigMap.

Дивись, як піднімаються (Ctrl-C щоб вийти зі спостереження):

```bash
kubectl get pods -n data -w
```

Чекаємо приблизно 2 хвилини:

```
NAME               READY   STATUS    RESTARTS   AGE
rabbitmq-7d4f...   1/1     Running   0          2m
redis-6b8c...      1/1     Running   0          2m
```

RabbitMQ стартує повільно (20–40 секунд) — це нормально.

---

## Крок 4. Підключити MongoDB Atlas

Atlas — правильний вибір і локально: M0 безкоштовний, це **справжній replica
set**, і це та сама база, яку використовуватиме AWS-деплой. Одним джерелом
відмінностей менше.

> **Чому обов'язково replica set.** Сервіси використовують transactional
> outbox: подія пишеться в колекцію `outbox`, а окремий watcher стежить за нею
> через **change stream**. Change streams існують тільки на replica set.
> Звичайний standalone-mongod дозволив би сервісам стартувати, а потім вони
> мовчки не публікували б жодної події — найгірший тип поломки, бо нічого не
> падає. Atlas M0 — replica set із коробки, тож це вже вирішено.

### 4.1. Дозволити доступ зі свого IP

Atlas за замовчуванням не пускає нікого. Кластер `kind` виходить у мережу
через твій ноутбук, тому дозволити треба **свою домашню IP-адресу**.

Atlas → **Network Access** → **Add IP Address** → **Add Current IP Address**
→ Confirm.

> Якщо працюєш із різних місць — доведеться додавати кожну нову адресу.
> `0.0.0.0/0` (пускати всіх) не став навіть тимчасово: M0-кластер із
> дефолтним паролем і відкритим доступом знаходять сканери за години.

### 4.2. Взяти connection string

Atlas → **Database** → **Connect** → **Drivers**. Скопіюй рядок виду:

```
mongodb+srv://platform:<db_password>@cluster0.xxxxx.mongodb.net/?retryWrites=true&w=majority
```

Нам потрібна тільки частина **до** `/?`:

```
mongodb+srv://platform:ТВІЙ_ПАРОЛЬ@cluster0.xxxxx.mongodb.net
```

Ім'я бази скрипт додасть сам — кожен сервіс отримає свою (`user-service`,
`order-service`, ...).

### 4.3. Покласти його у файл, а не в термінал

```bash
cd /Users/ajjya/Projects/archtenet/backend/platform-infra
cp .env.local.example .env.local
```

Відкрий `.env.local` у редакторі й встав свій рядок. Потім:

```bash
cd ..
source platform-infra/.env.local
echo "${MONGO_BASE_URI%%:*}"      # має надрукувати mongodb+srv — пароль не світимо
```

> Чому через файл, а не `export` прямо в терміналі: усе, що ти набираєш у
> терміналі, лягає в `~/.zsh_history` відкритим текстом. `.env.local` доданий
> у `.gitignore`, тож у git він теж не потрапить.

### 4.4. Створити namespace і спільний секрет

```bash
kubectl create namespace local
kubectl apply -n local -f platform-infra/demo/platform-secret.yaml
```

Подивись, що всередині:

```bash
kubectl get secret platform-local -n local -o jsonpath='{.data.REDIS_URL}' | base64 -d; echo
```

Це локальний замінник того, що в AWS робить External Secrets Operator:
однакові імена змінних, однаковий спосіб доставки в под (`envFrom`), інакше
тільки джерело.

`MONGO_URI` тут навмисно немає: у кожного сервісу своя база, тому для кожного
створюється окремий секрет `<сервіс>-mongo` — так пароль Atlas не потрапляє ні
в команду `helm --set`, ні у вивід `helm get values`.

> **Не хочеш чіпати Atlas?** Є запасний варіант — Mongo прямо в кластері:
> `kubectl apply -f platform-infra/demo/mongo-in-cluster.yaml`, і не
> встановлюй `MONGO_BASE_URI`. Скрипт сам це помітить і використає її.
> Коштує близько 1 GB пам'яті Docker.

---

## Крок 5. Підняти OPA (той, до якого ходить Envoy)

Кожен под має сайдкар Envoy, який на кожен запит питає OPA «пускати?». Якщо
OPA немає, Envoy відхиляє **все** — це правильна поведінка (`failure_mode_allow:
false`, краще відмовити, ніж пустити без перевірки), але виглядає точно як
зламаний сервіс. Тому OPA — раніше за сервіси.

```bash
cd /Users/ajjya/Projects/archtenet/backend/opa-policies
make build                        # збирає dist/bundle.tar.gz із bundle/*.rego
cd ..
kubectl apply -f platform-infra/demo/opa.yaml
kubectl create configmap opa-bundle -n opa-system \
  --from-file=bundle.tar.gz=opa-policies/dist/bundle.tar.gz \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/opa-pdp -n opa-system
kubectl rollout status  deployment/opa-pdp -n opa-system
```

Перевірка — has to be `Running`:

```bash
kubectl get pods -n opa-system
```

### Ключі для demo-токенів

Політика перевіряє **підпис** JWT проти JWKS усередині bundle — заголовкам
вона не вірить. Приватний ключ у git не лежить (і не має), тому згенеруй
свою пару один раз:

```bash
cd opa-policies
node demo/gen-keys.js       # пише demo/.keys/private-key.pem + bundle/jwks/data.json
make build                  # ОБОВ'ЯЗКОВО перезібрати: у bundle має бути новий JWKS
cd ..
kubectl create configmap opa-bundle -n opa-system \
  --from-file=bundle.tar.gz=opa-policies/dist/bundle.tar.gz \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl rollout restart deployment/opa-pdp -n opa-system
```

> Порядок тут важливий і його легко переплутати: `gen-keys.js` міняє публічний
> ключ у `bundle/jwks/data.json`, а `make build` запаковує його в тарбол. Якщо
> зібрати bundle до генерації ключів, OPA перевірятиме твої токени старим
> ключем і відхилятиме геть усе — виглядатиме як «політика зламана».

---

## Крок 6. Підняти ingress

Той самий `ingress-nginx`, що і в AWS, із тим самим класом `nginx-internal`
— тому Ingress-обʼєкти сервісів локально й у хмарі однакові.

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm upgrade --install ingress-nginx-internal ingress-nginx/ingress-nginx \
  --namespace ingress --create-namespace \
  -f platform-infra/demo/ingress-nginx-values.yaml \
  --wait --timeout 4m
```

Перевірка:

```bash
kubectl get pods -n ingress
kubectl get ingressclass
# Очікується: клас nginx-internal
```

> **Чому це не можна пропустити.** У кожного сервісу в Ingress є анотація
> `configuration-snippet`, яка проставляє `x-correlation-id` із заголовка
> `cf-ray`. Це початок наскрізного correlation-id — того самого, за яким
> потім шукається один запит через усі сервіси. `ingress-nginx` за
> замовчуванням такі анотації **забороняє** (з версії 1.9, і з 1.12 ще й
> окремим рівнем ризику), і webhook відхиляє весь Ingress з помилкою
> `annotation group ConfigurationSnippet contains risky annotation`. Файл
> `demo/ingress-nginx-values.yaml` вмикає обидва налаштування — без нього
> `helm install` сервісу просто впаде.

---

## Крок 7. Зібрати образ ОДНОГО сервісу

Не всіх одразу. Спершу один — щоб коли зламається, було зрозуміло, де саме.

```bash
cd /Users/ajjya/Projects/archtenet/backend
docker build -f user-service/Dockerfile -t user-service:local .
```

Зверни увагу на крапку в кінці — це **контекст збірки**, і він має бути
`backend/`, а не `backend/user-service/`. Dockerfile копіює не тільки свій
код, а ще й папку `contracts/`, тому зсередини сервісу збірка впаде.

Перший раз ~3–5 хвилин (качається `node:20-alpine`, ставляться залежності).

Перевірка:

```bash
docker images | grep user-service
```

---

## Крок 8. Завантажити образ у кластер

```bash
kind load docker-image user-service:local --name archtenet
```

Це неочевидний, але обов'язковий крок. Кластер `kind` живе у **своєму**
Docker-контейнері зі своїм сховищем образів — він не бачить образи твого
Docker напряму. `kind load` копіює образ усередину.

Якщо цей крок пропустити, под застрягне в `ErrImageNeverPull`.

---

## Крок 9. Встановити сервіс

Спершу секрет із адресою бази саме для цього сервісу:

```bash
kubectl create secret generic user-service-mongo -n local \
  --from-literal="MONGO_URI=${MONGO_BASE_URI}/user-service?retryWrites=true&w=majority"
```

(`${MONGO_BASE_URI}` підставиться з того, що ти зробила `source` на кроці 4.3
— пароль у команді не з'являється.)

Тепер сам сервіс:

```bash
helm upgrade --install user-service ./user-service/helm \
  --namespace local \
  -f platform-infra/demo/values-local.yaml \
  --set base-service.image.repository=user-service \
  --set base-service.image.tag=local \
  --set-json 'base-service.app.extraEnvFromSecrets=["platform-local","user-service-mongo"]'
```

Розбір команди по частинах:

| Частина | Що робить |
|---|---|
| `upgrade --install` | Постав, якщо немає; онови, якщо вже є. Зручно — можна запускати повторно |
| `user-service` | Ім'я релізу (як Helm називатиме цю установку) |
| `./user-service/helm` | Де лежить чарт |
| `--namespace local` | У який namespace класти |
| `-f ...values-local.yaml` | Той самий файл із вимикачами |
| `--set ...image.repository` | Брати образ `user-service:local`, а не з ghcr.io |
| `--set-json ...extraEnvFromSecrets` | Які секрети підмонтувати як змінні оточення: спільний + свій mongo |

Перед установкою корисно подивитись, що саме Helm збирається створити —
`template` нічого не змінює, просто друкує:

```bash
helm template user-service ./user-service/helm \
  -f platform-infra/demo/values-local.yaml \
  --set base-service.image.repository=user-service \
  --set base-service.image.tag=local | grep '^kind:'
```

Має надрукувати рівно три рядки: `Deployment`, `Service`, `ServiceAccount`.
Якщо бачиш `ExternalSecret` або `Ingress` — значить оверлей не підхопився,
перевір шлях до `values-local.yaml`.

---

## Крок 10. Перевірити, що сервіс живий

```bash
kubectl get pods -n local
```

Що означають стани:

| STATUS | Що це |
|---|---|
| `ContainerCreating` | Ще запускається, зачекай |
| `Running` + `READY 2/2` | Усе добре — два контейнери: `app` і `envoy-pep` |
| `Running` + `READY 1/2` | Сайдкар Envoy не піднявся — див. крок 5 (OPA) |
| `CrashLoopBackOff` | Стартує і падає по колу → дивись логи |
| `ErrImageNeverPull` | Забула `kind load` (крок 8) |
| `Pending` | Не вистачає пам'яті на ноді |

Логи — головний інструмент:

```bash
kubectl logs -n local deploy/user-service
kubectl logs -n local deploy/user-service -f     # стежити наживо
```

Тепер достукатись до сервісу. Ingress вимкнено, тому пробиваємо тунель:

```bash
kubectl port-forward -n local deploy/user-service 3000:3000
```

Термінал залишиться зайнятим — так і має бути. **Відкрий друге вікно
термінала** і там:

```bash
curl http://localhost:3000/health
```

Очікується JSON-відповідь про здоров'я сервісу.

**Якщо вона прийшла — ти розгорнула мікросервіс у Kubernetes.**

### Перевірити авторизацію (найцікавіше)

Порт 3000 вище — це **застосунок напряму**, повз Envoy. Так роблять проби
kubelet, і так ти щойно обійшла авторизацію. Тепер зайдемо як справжній
трафік — через ingress, тобто тим самим шляхом, що й у хмарі.

Зупини попередній `port-forward` (Ctrl-C) — він більше не потрібен. Ingress
слухає на порту **8081**, який `kind` прокинув із твого ноутбука.

Хостнейм `user-service.internal.archtenet.com` нікуди не резолвиться, і це
нормально: nginx маршрутизує за заголовком `Host`, а не за DNS. Тому в
`/etc/hosts` нічого прописувати не треба — досить передати заголовок:

```bash
curl -i -H 'Host: user-service.internal.archtenet.com' \
  http://localhost:8081/api/v1/users
```

Очікується **403 Forbidden**. Це не поломка — це OPA сказав «ні», бо запит
без токена. Той самий код, що працюватиме в AWS.

Тепер із токеном адміна:

```bash
cd /Users/ajjya/Projects/archtenet/backend/opa-policies
TOKEN=$(node demo/mint-token.js admin@archtenet.dev admin | tail -1)
curl -i -H 'Host: user-service.internal.archtenet.com' \
  -H "Authorization: Bearer $TOKEN" http://localhost:8081/api/v1/users
```

Очікується **200** і відповідь сервісу.

І токен із роллю, якій не можна:

```bash
BUYER=$(node demo/mint-token.js buyer@archtenet.dev buyer | tail -1)
curl -i -H 'Host: user-service.internal.archtenet.com' \
  -H "Authorization: Bearer $BUYER" http://localhost:8081/api/v1/users
```

Знову **403** — токен валідний, підпис правильний, але роль не та.

### Correlation-id

Передай `cf-ray` — так робить Cloudflare перед справжнім кластером — і
подивись, як він перетворюється на `x-correlation-id`, з яким запит піде
далі через усі сервіси:

```bash
curl -s -H 'Host: user-service.internal.archtenet.com' \
  -H 'cf-ray: 8abc123def456-FRA' \
  -H "Authorization: Bearer $TOKEN" \
  http://localhost:8081/api/v1/users -o /dev/null -w '%{http_code}\n'

kubectl logs -n local deploy/user-service -c app --tail=5 | grep -o '8abc123def456-FRA'
```

Той самий рядок має бути в логах сервісу. Це критерій приймання №3 у
мініатюрі — і саме заради нього ingress не варто було вимикати.

Побачити, **чому** OPA так вирішив:

```bash
kubectl logs -n opa-system deploy/opa-pdp --tail=20
```

Кожне рішення друкується з повним input і результатом. Це найкорисніший
інструмент, коли щось відхиляється, а ти не розумієш чому.

> Що тут щойно сталося: запит зайшов в Envoy → Envoy по gRPC спитав OPA
> (`ext_authz`) → OPA перевірив **підпис** JWT проти JWKS усередині bundle,
> дістав роль і зіставив із `route_table` в `envoy.rego` → відповів
> allow/deny → Envoy або пропустив запит на `127.0.0.1:3000`, або віддав 403,
> не потурбувавши застосунок. У AWS відрізняється рівно одне: bundle туди
> приїжджає з S3, а не з ConfigMap.

Далі — решта сервісів.

---

## Крок 11. Решта сервісів

Тепер, коли один сервіс точно працює, повторювати ті самі чотири команди 11
разів немає сенсу:

```bash
source platform-infra/.env.local     # якщо відкрила нове вікно термінала
./platform-infra/demo/run-demo.sh
```

Скрипт робить рівно те саме, що ти зробила руками: піднімає бази, секрет і
OPA (ідемпотентно — повторний запуск нічого не ламає), а далі для кожного
сервісу `docker build` → `kind load` → секрет із MONGO_URI →
`helm upgrade --install`.

Займе 20–40 хвилин (кожен образ збирається окремо). Можна й вибірково:

```bash
./platform-infra/demo/run-demo.sh order-service catalog-service
```

Наприкінці:

```bash
kubectl get pods -n local
```

---

## Крок 12. Подивитись, що всередині

Це найкорисніша частина — саме тут архітектура стає видимою.

**Усі сервіси через один порт.** Після кроку 11 кожен сервіс доступний за
своїм хостнеймом на тому самому 8081 — жодних `port-forward`:

```bash
curl -H 'Host: order-service.internal.archtenet.com' http://localhost:8081/api/v1/orders
curl -H 'Host: cart-bff.internal.archtenet.com'      http://localhost:8081/api/v1/cart
kubectl get ingress -n local        # хостнейм і шлях кожного сервісу
```

**Черги RabbitMQ** (тут видно саги й події):

```bash
kubectl port-forward -n data svc/rabbitmq 15672:15672
```

Відкрий http://localhost:15672 — логін `guest`, пароль `guest`. Вкладка
Queues покаже черги сервісів і скільки в них повідомлень.

**Дані в MongoDB** — через Atlas → Database → **Browse Collections**. Побачиш
окрему базу на кожен сервіс, а в кожній — робочу колекцію і `outbox`. Саме в
`outbox` лежать ті події, які watcher вичитує через change stream і
відправляє в RabbitMQ.

Якщо зручніше з консолі (за наявності `mongosh` локально):

```bash
mongosh "$MONGO_BASE_URI/user-service"
```

```javascript
show collections                  // users, outbox
db.outbox.find().limit(5)
```

Вийти — `exit`.

**Що взагалі є в кластері:**

```bash
kubectl get all -n local
kubectl describe pod -n local -l app.kubernetes.io/name=user-service
```

---

## Коли зламається

| Симптом | Причина | Що робити |
|---|---|---|
| `ErrImageNeverPull` | Образ не завантажено в kind | `kind load docker-image <svc>:local --name archtenet` |
| `CrashLoopBackOff`, у логах `MongoServerSelectionError` | Atlas не пускає твій IP | Atlas → Network Access → Add Current IP Address |
| У логах `bad auth` / `Authentication failed` | Не той пароль у `MONGO_BASE_URI` | Перезбери рядок в Atlas → Connect → Drivers |
| У логах `MONGO_URI is not defined` | Забула `source platform-infra/.env.local`, секрет створився порожній | `source`, тоді перестворити секрет і `helm upgrade` |
| `CrashLoopBackOff`, у логах `ECONNREFUSED` до rabbitmq | RabbitMQ ще стартує (він повільний) | Зачекай 2 хв, под перезапуститься сам |
| `Pending`, `Insufficient memory` | Мало пам'яті в Docker | Docker Desktop → Resources → 8 GB+, або став менше сервісів |
| `no matches for kind "ExternalSecret"` | Оверлей `values-local.yaml` не підхопився | Перевір шлях у `-f` |
| `OOMKilled` | Поду не вистачило ліміту пам'яті | Те саме, що `Pending` |
| `curl: connection refused` на 8081 | Кластер створено без `--config demo/kind-config.yaml` | `kind delete cluster --name archtenet` і створити заново з конфігом (крок 2) |
| `403` з `server: envoy` на 8080 | Чужий процес на порту — саме тому ingress на 8081 | Нічого, використовуй 8081 |
| `helm install` сервісу падає з `ConfigurationSnippet contains risky annotation` | Ingress-контролер поставлено без `demo/ingress-nginx-values.yaml` | Перевстанови його (крок 6) |
| Ingress є, але `404` | Не той `Host` або не той шлях | `kubectl get ingress -n local` — звір хостнейм і path |
| Усі запити 403, навіть з токеном | Bundle зібрано ДО `gen-keys.js` — у ньому старий JWKS | `node demo/gen-keys.js && make build`, перестворити configmap `opa-bundle`, `kubectl rollout restart deployment/opa-pdp -n opa-system` |
| Под `1/2`, Envoy не стартує | OPA не піднятий | `kubectl get pods -n opa-system` — має бути `Running` (крок 5) |
| `CrashLoopBackOff` в `opa-pdp` | ConfigMap `opa-bundle` не створено | Крок 5, команда `kubectl create configmap opa-bundle ...` |

Три команди, які відповідають майже на все:

```bash
kubectl logs -n local deploy/<сервіс>          # що каже сам застосунок
kubectl describe pod -n local <ім'я-пода>      # що каже Kubernetes (події внизу)
kubectl get events -n local --sort-by=.lastTimestamp
```

---

## Крок 13. Прибрати за собою

Зупинити все, залишивши кластер:

```bash
helm list -n local -q | xargs -r -n1 helm uninstall -n local
```

Знести кластер повністю (Docker-контейнер видаляється, пам'ять звільняється):

```bash
kind delete cluster --name archtenet
```

Підняти заново — з кроку 2. Другий раз займе значно менше: Docker-образи вже
складені й закешовані.

---

## Що далі

Коли локально все піднімається й ти розумієш, що робить кожна команда —
переходь до [AWS-GETTING-STARTED.md](AWS-GETTING-STARTED.md): акаунт AWS,
ключі доступу й перший кластер у хмарі. Після нього —
[AWS-DEPLOYMENT.md](AWS-DEPLOYMENT.md) з решти платформи. Там той самий Helm
і ті самі команди `kubectl`, але додається хмара: справжні секрети, справжня
авторизація й публічний домен.

Корисна вправа перед тим: знеси кластер і підніми все з нуля ще раз, не
підглядаючи. Другий прогін показує, що ти справді зрозуміла, а не повторила.
