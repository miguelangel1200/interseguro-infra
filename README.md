# interseguro-infra

Infraestructura como código (**Terraform**) para desplegar las APIs
`interseguro-go-api` y `interseguro-node-api` en **Google Cloud Run**, con
imágenes en **Artifact Registry** construidas por **GitHub Actions** mediante
Workload Identity Federation. Incluye `docker-compose.yml` para la ejecución
local de los tres servicios.

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

- CORS restringido al origen del frontend vía `cors_origin`.
- JWT compartido (`JWT_SECRET`/`ISSUER`/`AUDIENCE`) almacenado en **Secret Manager**.
- Acceso público (IAM `allUsers`); la protección real es el JWT.

## Repositorios (privados)

| Repo                   | Contenido                                  |
|------------------------|--------------------------------------------|
| interseguro-go-api     | API Go (Fiber) + `deploy.sh` + CI image    |
| interseguro-node-api   | API Node/TS (Express) + `deploy.sh` + CI   |
| interseguro-frontend   | Frontend React + workflow Cloudflare Pages |
| interseguro-infra      | Este repo (Terraform + docker-compose)     |

## Despliegue (GCP)

```bash
# 1. Requisitos: gcloud autenticado, billing y APIs habilitadas
#    (run, artifactregistry, secretmanager, compute). Copiar tfvars:
cp terraform.tfvars.example terraform.tfvars   # completar valores

# 2. Inicializar y aplicar
terraform init
terraform apply          # Artifact Registry, Secret Manager, Cloud Run y WIF

# 3. Subir imágenes (alternativo al CI): desde cada repo de servicio
./deploy.sh
```

El CI de `interseguro-go-api` y `interseguro-node-api` construye la imagen
(`docker build` + `docker push`) en cada push a `main`. Secrets de CI:
`WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT`, `GCP_PROJECT_ID`, `GCP_REGION`.

## URLs

| Servicio            | URL                                                            |
|---------------------|----------------------------------------------------------------|
| Frontend (Pages)    | https://interseguro-frontend.pages.dev                         |
| API Go (Cloud Run)  | https://interseguro-go-api-c3hg4n5aza-uc.a.run.app             |
| API Node (Cloud Run)| https://interseguro-node-api-c3hg4n5aza-uc.a.run.app           |

Health checks: `GET /health` en ambas APIs.

## Credenciales

Las credenciales de acceso y los secretos de la entrega se comparten **por
correo** (no se documentan en el repositorio). `terraform.tfvars` no se
versiona; `terraform.tfvars.example` es la plantilla para valores locales.

## Despliegue local

```bash
docker compose up --build
# go-api: http://localhost:8080  node-api: http://localhost:3000  frontend: http://localhost:80
```

## CI/CD y autenticación en GCP

- **WIF** (Workload Identity Federation): pool/proveedor OIDC de GitHub
  restringido a los repositorios del owner; los workflows se autentican sin
  credenciales de larga duración.
- El SA `github-actions` tiene únicamente los permisos necesarios:
  `roles/artifactregistry.writer` por repositorio y
  `roles/serviceusage.serviceUsageConsumer`.
- El SA de runtime de Cloud Run (compute por defecto) lee los secrets con
  `roles/secretmanager.secretAccessor`.

## Terraform apply manual vs CI

- **Infraestructura** (este repo): `terraform apply` manual.
- **Imágenes** (repos de servicio): GitHub Actions en cada push a `main`.
- **Frontend**: GitHub Actions → `cloudflare/wrangler-action` (Direct Upload).
