# Script de tunnel Cloudflare

Este script cria ou reutiliza um tunnel nomeado do `cloudflared`, aponta um host publico para ele via DNS da Cloudflare e conecta esse host a um servico local.

## Pre-requisitos

- `cloudflared` instalado.
- Dominio gerenciado pela Cloudflare.
- Login local feito com:

```bash
cloudflared tunnel login
```

Voce tambem pode pedir para o proprio script abrir o login usando `--login`.

## Uso

```bash
cloudflared-tunnel --local http://localhost:3000 --public app.seudominio.com
```

Atalhos aceitos para o host local:

```bash
cloudflared-tunnel --local 3000 --public app.seudominio.com
cloudflared-tunnel --local localhost:8080 --public api.seudominio.com
cloudflared-tunnel --local site.host --public site.drkgarage.com.br
```

Quando o `--local` for um host local sem protocolo, como `site.host`, o script assume `https://site.host` e deduz automaticamente:

- `--origin-host site.host`
- `--origin-sni site.host`
- `--no-tls-verify`

O comando curto abaixo:

```bash
cloudflared-tunnel --local site.host --public site.drkgarage.com.br
```

gera uma conexao equivalente a:

```bash
cloudflared-tunnel \
  --local https://site.host \
  --public site.drkgarage.com.br \
  --origin-host site.host \
  --origin-sni site.host \
  --no-tls-verify
```

Se voce quiser validar o certificado TLS do origin local, passe `--tls-verify`.

## Gerenciar tunnels ativos

Por padrao, o script inicia o `cloudflared` em background, salva o PID e grava logs em `~/.cloudflared-tunnel-manager/logs`.

Para listar:

```bash
cloudflared-tunnel --list
```

Esse comando mostra os tunnels gerenciados pelo script e tambem os tunnels que a Cloudflare reporta com conexoes ativas na conta.

Para parar, voce pode informar o host local, o host publico ou o nome do tunnel:

```bash
cloudflared-tunnel --stop site.host
cloudflared-tunnel --stop site.drkgarage.com.br
cloudflared-tunnel --stop cf-site.drkgarage.com.br
```

Se quiser rodar preso ao terminal, mostrando os logs:

```bash
cloudflared-tunnel --local site.host --public site.drkgarage.com.br --foreground
```

Por padrao, o nome do tunnel sera `cf-<host-publico>`. Para definir outro nome:

```bash
cloudflared-tunnel --name meu-app --local 3000 --public app.seudominio.com
```

Se ja existir um registro DNS para o host publico e voce quiser sobrescrever:

```bash
cloudflared-tunnel --local 3000 --public app.seudominio.com --overwrite-dns
```

Para apenas criar/configurar sem conectar imediatamente:

```bash
cloudflared-tunnel --local 3000 --public app.seudominio.com --no-run
```

Depois, conecte com:

```bash
cloudflared tunnel run --url http://localhost:3000 cf-app.seudominio.com
```
