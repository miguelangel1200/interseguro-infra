# Seguridad — Reto Interseguro

Este documento resume las medidas de seguridad implementadas y las mejoras
aplicadas (Fases A, B y C) antes de la entrega, así como las limitaciones
conocidas y la hoja de ruta recomendada para producción.

## Resumen

- Autenticación basada en **JWT (HS256)** compartido entre las APIs Go y Node,
  con `issuer`/`audience` verificados en ambas.
- La contraseña se almacena como **hash bcrypt** (nunca en texto plano).
- Los secretos viven en **Secret Manager** (no en variables de entorno en
  claro) y en **secrets de GitHub** para CI.
- **CORS restringido** al origen del frontend; **cabeceras de seguridad** en
  todas las respuestas y **CSP** en el frontend.
- Protección contra abuso: **rate limiting** en login, **límites de tamaño de
  matriz/body** y **errores internos enmascarados**.
- CI con **Workload Identity Federation** (sin credenciales de larga duración)
  y roles de IAM **acotados al mínimo**.
- Escaneo de dependencias: **govulncheck** (Go) y **npm audit** (Node/Front).

## Autenticación y sesiones

| Aspecto                | Estado                                                                |
|------------------------|-----------------------------------------------------------------------|
| Algoritmo JWT          | HS256, secreto fuerte (64 chars aleatorios) en Secret Manager         |
| Verificación           | Firma + `issuer` + `audience` + expiración (2h) en ambas APIs         |
| Contraseña             | Comparación **bcrypt** (`EnvUserRepository`); el valor en entorno/secret es el hash |
| Almacenamiento token   | **En memoria** en el frontend (sin `localStorage`); se pierde al recargar la página y se debe volver a iniciar sesión |
| Rate limiting          | `POST /auth/login`: 10 intentos / 15 min / IP → `429 RATE_LIMITED`    |
| Errores                | `401` genérico sin revelar si el usuario existe                       |

> **Limitación (httpOnly cookie):** una sesión con cookie `httpOnly` (a prueba
> de XSS) no es viable con la arquitectura actual `frontend → go → node` porque
> Go necesita leer el JWT enviado por el navegador y las cookies no viajan
> entre orígenes distintos. La mitigación aplicada es token **en memoria** +
> CSP estricta. Para producción con cookie httpOnly se requiere un **BFF o API
> gateway** (por ejemplo, Cloudflare Workers/Pages Functions) que centralice el
> login y la propagación del token.

## Secretos

- **GCP Secret Manager:** `auth-user`, `auth-password` (hash bcrypt) y
  `jwt-secret` se inyectan en Cloud Run como `value_source.secret_key_ref`
  (versión `latest`). El SA de runtime (compute por defecto) tiene
  `roles/secretmanager.secretAccessor` solo sobre esos secrets.
- **GitHub:** secrets de repositorio (`WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT`,
  `GCP_PROJECT_ID`, `GCP_REGION`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`,
  `VITE_GO_API_URL`, `VITE_NODE_API_URL`). Sin coste y sin exponer valores en el
  código.
- `terraform.tfvars` **nunca se versiona** (en `.gitignore`); contiene solo
  valores locales de referencia. `terraform.tfvars.example` es la plantilla.

## CORS y cabeceras

- **CORS:** `cors_origin = "https://interseguro-frontend.pages.dev"` en ambas
  APIs (env `CORS_ORIGIN`). Orígenes ajenos no reciben `Access-Control-Allow-Origin`
  (el navegador bloquea la respuesta).
- **Node API:** `helmet` (con `frameguard: DENY` y CSP deshabilitada, gestionada
  en Pages). Incluye `X-Content-Type-Options`, `X-Frame-Options`,
  `Referrer-Policy`, etc.
- **Go API:** middleware `securityHeaders()` (nosniff, DENY, no-referrer,
  X-XSS-Protection 0).
- **Frontend (Pages):** `public/_headers` con **CSP estricta**:
  `default-src 'self'`, scripts propios, estilos propios + Google Fonts,
  `connect-src` solo a las 2 APIs Cloud Run, `frame-ancestors 'none'`,
  `form-action 'self'`, `object-src 'none'`.

## Protección contra abuso (DoS / fuerza bruta)

- **Tamaño de matriz:** máximo 100×100 en ambas APIs
  (`MATRIX_TOO_LARGE` / `413`) — el QR es O(n³).
- **Body limit:** 1 MiB en Node (`express.json`) y Go (`BodyLimit`).
- **Rate limiting:** login (10/15 min/IP).
- **Error masking:** el detalle interno del fallo del servicio Node
  (`NODE_API_UNAVAILABLE`) no se expone al cliente; los errores 500 devuelven
  mensaje genérico.

## Dependencias y análisis

- **Go:** `govulncheck` → **0 vulnerabilidades afectando el código**. Se
  actualizaron `gofiber/fiber/v2` a `v2.52.12` y `golang-jwt/jwt/v5` a
  `v5.2.2`; Dockerfile y CI usan **Go 1.26**. Comando: `make vuln` (usa
  `GOTOOLCHAIN=go1.26.6`).
- **Node/Front:** `npm audit --omit=dev` → **0 vulnerabilidades**.
- Tests con cobertura: Node ~98% (statements), Go ~98% (internal). CI ejecuta
  los tests en cada push (`npm test` / `go test ./...`).

## CI/CD (GitHub Actions) e IAM

- **WIF** (Workload Identity Federation): pool/proveedor OIDC restringido a
  los repositorios del owner (`attribute_condition`). Sin service account keys.
- El SA `github-actions` solo tiene:
  - `roles/artifactregistry.writer` **por repositorio** (go-api y node-api).
  - `roles/serviceusage.serviceUsageConsumer` (mínimo para consumir APIs).
  - Bindings `workloadIdentityUser` + `serviceAccountTokenCreator` sobre sí
    mismo para la sesión federada.
- Se **eliminaron** roles amplios: `cloudbuild.builds.editor` (proyecto),
  `artifactregistry.writer` (proyecto) y `storage.objectAdmin` (bucket), porque
  el CI construye con `docker build` + `docker push` directos.

## Infraestructura (GCP / Cloudflare)

- **TLS** gestionado por Cloud Run y Cloudflare.
- Cloud Run: IAM `allUsers` invoker (acceso público) con protección real por
  JWT; `ingress = INGRESS_TRAFFIC_ALL`.
- **Pages:** despliegue automático por CI (`wrangler pages deploy`), `_redirects`
  para SPA, headers/`_headers` con CSP.

## Verificación aplicada

- Preflight CORS desde el origen Pages → permitido; desde un origen ajeno →
  sin cabecera ACAO (bloqueado).
- Cabeceras de seguridad presentes en Go, Node y Pages.
- Matriz 101×1 → `413 MATRIX_TOO_LARGE`.
- Login correcto con hash bcrypt (vía Secret Manager) y 401 con password
  incorrecta.
- `govulncheck` (Go 1.26.6): 0 vulnerabilidades afectando el código.

## Hoja de ruta para producción

1. **Sesión httpOnly + CSRF:** migrar a cookie `httpOnly`/`SameSite` con un
   BFF o API gateway que centralice la autenticación y la propagación del
   token (la arquitectura multi-origen actual lo impide).
2. **Rotación de secretos:** versionar los secrets en Secret Manager y rotar
   `jwt-secret` y `auth-password` periódicamente.
3. **Revocación/refresh de tokens:** refresh tokens con rotación y lista de
   revocación para logout activo.
4. **Rate limiting por usuario + WAF:** extender el rate limit más allá del
   login y considerar Cloud Armor/Cloudflare WAF para los endpoints públicos.
5. **Logging y observabilidad:** logs estructurados (Cloud Logging) con
   correlación (`x-cloud-trace-context` ya presente) y alertas sobre 401/429.
6. **Vulnerabilidades de stdlib:** mantener Go actualizado (los hallazgos de
   stdlib de govulncheck se resuelven con Go ≥ 1.26.6; ya en Dockerfile/CI).
