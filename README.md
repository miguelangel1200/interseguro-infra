# interseguro-infra

Infraestructura del Reto Interseguro: despliega las APIs en **Google Cloud Run**
mediante Terraform, con imágenes en **Artifact Registry** construidas por
**GitHub Actions** (Workload Identity Federation). Incluye `docker-compose.yml`
para el despliegue local.

## Arquitectura

```
[Cloudflare Pages]  https://interseguro-frontend.pages.dev
      │  VITE_GO_API_URL / VITE_NODE_API_URL
      ▼
Cloud Run: interseguro-go-api   (POST /process, rotación + factorización QR)
      │  JWT (propagado)
      ▼
Cloud Run: interseguro-node-api (POST /auth/login, POST /statistics)
```

CORS habilitado en ambas APIs y **restringido** al origen del frontend
(`https://interseguro-frontend.pages.dev`) vía `cors_origin`. JWT compartido
(`JWT_SECRET`/`ISSUER`/`AUDIENCE`) almacenado en **Secret Manager**. Acceso
público (IAM `allUsers`); la protección real es el JWT.

> **Seguridad:** consulta [`SECURITY.md`](./SECURITY.md) para el detalle completo
> de las medidas aplicadas (Fases A/B/C), limitaciones y hoja de ruta.

## Repositorios (privados)

| Repo                   | Contenido                                  |
|------------------------|--------------------------------------------|
| interseguro-go-api     | API Go (Fiber) + `deploy.sh` + CI image    |
| interseguro-node-api   | API Node/TS (Express) + `deploy.sh` + CI   |
| interseguro-frontend   | Frontend React + workflow Cloudflare Pages |
| interseguro-infra      | Este repo (Terraform + docker-compose)     |

## Despliegue (GCP)

```bash
# 1. Requisitos: gcloud autenticado con billing y APIs habilitadas
#    (run, artifactregistry, cloudbuild). Copiar tfvars de ejemplo:
cp terraform.tfvars.example terraform.tfvars   # completar valores

# 2. Inicializar y aplicar
terraform init
terraform apply          # crea Artifact Registry, Cloud Run y WIF

# 3. Subir imágenes (alternativo al CI): desde cada repo de servicio
./deploy.sh
```

El CI de `interseguro-go-api` y `interseguro-node-api` sube la imagen a
Artifact Registry en cada push a `main` (secrets `WIF_PROVIDER`,
`GCP_SERVICE_ACCOUNT`, `GCP_PROJECT_ID`, `GCP_REGION`).

## URLs de producción (prueba técnica)

| Servicio            | URL                                                            |
|---------------------|----------------------------------------------------------------|
| Frontend (Pages)    | https://interseguro-frontend.pages.dev                         |
| API Go (Cloud Run)  | https://interseguro-go-api-c3hg4n5aza-uc.a.run.app             |
| API Node (Cloud Run)| https://interseguro-node-api-c3hg4n5aza-uc.a.run.app           |

Health checks: `GET /health` en ambas APIs.

## Credenciales (solo prueba técnica)

| Variable      | Valor                                                              |
|---------------|--------------------------------------------------------------------|
| AUTH_USER     | `admin`                                                            |
| Login         | `admin` / `password123` (la contraseña se compara contra un hash bcrypt) |
| AUTH_PASSWORD | hash bcrypt de `password123` (en Secret Manager, nunca en claro)    |
| JWT_SECRET    | secreto aleatorio en Secret Manager (no versionado)                 |

> **Producción:** rotar el `jwt-secret` y el `auth-password` (Secret Manager),
> restringir IAM y considerar un BFF para sesiones httpOnly. Ver
> [`SECURITY.md`](./SECURITY.md).

## Despliegue local

```bash
docker compose up --build
# go-api: http://localhost:8080  node-api: http://localhost:3000  frontend: http://localhost:80
```

## WIF (Workload Identity Federation)

`main.tf` crea el pool/proveedor OIDC de GitHub, el SA `github-actions` y los
bindings de IAM. Los workflows se autentican sin credenciales de larga duración.

## Terraform apply manual vs CI

- **Infraestructura** (este repo): `terraform apply` manual (o CI dedicado).
- **Imágenes** (repos de servicio): GitHub Actions en cada push a `main`.
- **Frontend**: GitHub Actions → `cloudflare/wrangler-action` (Direct Upload).
