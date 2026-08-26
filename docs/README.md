# platform-infra/docs

## Розгортання — читати по порядку

| | Документ | Що дає | Коштує |
|---|---|---|---|
| 1 | [LOCAL-DEPLOYMENT.md](LOCAL-DEPLOYMENT.md) | Kubernetes на ноутбуці (kind): бази, образи, Helm, `kubectl` | $0 |
| 2а | [AWS-GETTING-STARTED.md](AWS-GETTING-STARTED.md) | Акаунт AWS, IAM-ключі, попередження про витрати, перший кластер через Terraform | ~$0.035/год |
| 2б | [AWS-DEPLOYMENT.md](AWS-DEPLOYMENT.md) | Решта платформи: Atlas, Cognito, секрети, OPA, Cloudflare Tunnel, CI/CD | те саме |

Порядок не косметичний. Локальний прогін прибирає половину джерел помилок
(IAM, мережа, секрети) і залишає чистий Kubernetes. Якщо почати з AWS, на
першій же поламці не буде зрозуміло, у чому річ — у Helm-чарті чи в правах.

## Перевірка й діагностика

| Документ | Про що |
|---|---|
| [MANUAL-TESTING.md](MANUAL-TESTING.md) | Ручні сценарії: кошик → замовлення → сага → нотифікація |
| [find-by-rayid.md](find-by-rayid.md) | Як простежити один запит крізь усі сервіси за `cf-ray` |

`ACCEPTANCE.md` — звіт про шість критеріїв приймання, який генерує
[`../acceptance/run-acceptance.ts`](../acceptance). Зараз його немає в робочій
копії (файл є в git, але видалений на диску) — перегенерувати або відновити
з git.

## Інфраструктура

Технічні подробиці Terraform — [../terraform/README.md](../terraform/README.md):
чому два корені, скільки що коштує, як IRSA працює без EKS і що саме
однонодовий кластер віддає в обмін на ціну.
